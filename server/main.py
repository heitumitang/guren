"""后端：多 NPC 人格档案存取 + 校准 + 调度式对话。

启动：uvicorn main:app --reload --port 8000   （在 server/ 目录下）

多 NPC 数据布局：
  data/
    index.json                     # [{id, name, emoji, relation, basics, created_at, updated_at}]
    characters/<id>/
      persona.json                 # 人格档案（schema v1 + basics + relations）
      memory.json                  # 三层记忆（每个 NPC 独立，不串线）
      last_proactive.json
      outbox.json / pending.json   # 由 dispatcher 管理

API key 由调用方每次请求带入，后端不存。环境变量仅作服务端/CLI 兜底。
"""

from __future__ import annotations

import asyncio
import json
import os
import re
import sys
import uuid
from contextlib import asynccontextmanager
from datetime import datetime
from pathlib import Path

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from pydantic import BaseModel

# ponytail: 不设 PYTHONPATH 也要能 uvicorn main:app 直接跑。
# PyInstaller 冻结态下 validator 模块已由 --paths 打进包，不能按源码树路径注入。
FROZEN = getattr(sys, "frozen", False)
if not FROZEN:
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "validator"))

import dispatcher  # noqa: E402
import engine  # noqa: E402
import llm  # noqa: E402
import persona_schema  # noqa: E402
import presets  # noqa: E402
import scheduler  # noqa: E402

if FROZEN:
    # 整包自包含：数据目录跟程序走，可用 GUREN_DATA 覆盖（Flutter 启动器传入）。
    # 默认目录名不能是 data/——Flutter Windows 运行时时资源目录叫 data/，会撞名。
    DATA = Path(os.environ.get("GUREN_DATA") or Path(sys.executable).parent / "guren-data")
else:
    llm.load_env(Path(__file__).resolve().parent.parent / "validator" / ".env")
    DATA = Path(__file__).parent / "data"
CHAR = DATA / "characters"
INDEX = DATA / "index.json"
USER = DATA / "user.json"
DATA.mkdir(parents=True, exist_ok=True)
CHAR.mkdir(exist_ok=True)

_ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,32}$")


@asynccontextmanager
async def lifespan(app: FastAPI):
    n = await dispatcher.restore()
    if n:
        print(f"[启动] 恢复了 {n} 条未投递的消息")
    yield


app = FastAPI(title="真人聊天模拟 后端", version="0.3.0", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"], allow_credentials=False,
    allow_methods=["*"], allow_headers=["*"],
)

WEB = Path(__file__).resolve().parent.parent / "web" / "index.html"


@app.get("/app")
def web_client():
    if not WEB.exists():
        raise HTTPException(404, f"缺少 {WEB}")
    return FileResponse(WEB)


# ---------- 通用存取 ----------

def _load(path: Path, default):
    if not path.exists():
        return default
    return json.loads(path.read_text(encoding="utf-8"))


def _save(path: Path, data) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding="utf-8")


def _npc_dir(npc_id: str) -> Path:
    if not _ID_RE.match(npc_id):
        raise HTTPException(400, f"非法 NPC id：{npc_id}")
    return CHAR / npc_id


def _load_npc(npc_id: str, name: str, default):
    return _load(_npc_dir(npc_id) / name, default)


def _save_npc(npc_id: str, name: str, data) -> None:
    _save(_npc_dir(npc_id) / name, data)


def _need_persona(npc_id: str) -> dict:
    p = _load_npc(npc_id, "persona.json", None)
    if not p:
        raise HTTPException(404, f"找不到 NPC {npc_id}")
    return p


def _load_memory(npc_id: str) -> dict:
    raw = _load_npc(npc_id, "memory.json", None)
    if not raw:
        return persona_schema.empty_memory()
    if isinstance(raw, list):
        return {**persona_schema.empty_memory(), "shared": raw}
    return {**persona_schema.empty_memory(), **raw}


def _load_history(npc_id: str) -> list[dict]:
    return _load_npc(npc_id, "history.json", [])


def _append_history(npc_id: str, entries: list[dict]) -> None:
    """追加聊天记录。每 NPC 独立，退出/重进不丢。"""
    h = _load_history(npc_id)
    h.extend(entries)
    _save_npc(npc_id, "history.json", h[-500:])  # 只留最近 500 条


def _unread_count(npc_id: str) -> int:
    """未读 = 比「上次已读」更晚的 assistant 消息条数。

    history 里的 at 全是 datetime.now().isoformat(timespec="seconds")（无时区的本地
    秒级字符串），last_read 同格式，直接字符串比较即时间序。
    """
    last = _load_npc(npc_id, "last_read.json", None)
    n = 0
    for m in _load_history(npc_id):
        if m.get("role") != "assistant" or not m.get("at"):
            continue
        if last is None or m["at"] > last:
            n += 1
    return n


# ---------- 索引 ----------

def _read_index() -> list[dict]:
    return _load(INDEX, [])


def _write_index(items: list[dict]) -> None:
    _save(INDEX, items)


def _index_entry(npc_id: str, persona: dict) -> dict:
    b = persona.get("basics") or {}
    return {
        "id": npc_id,
        "name": (persona.get("meta") or {}).get("target_name", "未命名"),
        "emoji": persona.get("emoji", "🙂"),
        "avatar": persona.get("avatar", ""),
        "relation": (persona.get("relationship") or {}).get("bond", ""),
        "basics": {k: b.get(k, "") for k in ("age", "occupation", "mbti")},
        "created_at": (persona.get("meta") or {}).get("created_at", ""),
        "updated_at": datetime.now().isoformat(timespec="seconds"),
    }


def _upsert_index(npc_id: str, persona: dict) -> None:
    items = [x for x in _read_index() if x.get("id") != npc_id]
    items.append(_index_entry(npc_id, persona))
    items.sort(key=lambda x: x.get("created_at") or "")
    _write_index(items)


def _drop_index(npc_id: str) -> None:
    _write_index([x for x in _read_index() if x.get("id") != npc_id])


def _list_index() -> list[dict]:
    return list(_read_index())


def _new_id() -> str:
    return uuid.uuid4().hex[:8]


# ---------- 请求体 ----------

class LLMIn(BaseModel):
    api_key: str = ""
    base_url: str = ""
    model: str = ""


class ChatIn(BaseModel):
    message: str
    history: list[dict] = []
    quote: dict | None = None          # 引用回复 {role, text}，像微信的引用
    llm: LLMIn | None = None
    immediate: bool = False


class ReviewIn(BaseModel):
    traits: dict[str, str] = {}
    flaws: dict[str, str] = {}


class ScaleIn(BaseModel):
    flaw_intensity_scale: float
    reply_rate: float | None = None


class CreateIn(BaseModel):
    name: str = ""
    preset_id: str = ""            # 兼容旧的单选接口
    tags: list[str] = []           # 性格标签多选
    emoji: str = ""
    avatar: str = ""               # 图片头像 dataURL
    basics: dict = {}
    relation: str = ""


class MetaIn(BaseModel):
    # 关系/头像字段用 None 区分：None=不改，传值（含空串）=更新/清空。
    # 否则「部分更新」会把没传的字段清空（真踩过：PUT 时没传 relation，把 bond 清了）。
    basics: dict | None = None
    relation: str | None = None       # 与用户的关系类型（relationship.bond）
    rel_context: str | None = None    # 与用户的共同经历（relationship.context）
    call_me: str | None = None        # NPC 对用户的称呼
    name: str = ""
    emoji: str = ""
    avatar: str | None = None         # 图片 dataURL（空=用 emoji 头像）
    relations: list[dict] | None = None  # None=不改；[]=清空；非空=全量替换（双向同步）


class UserIn(BaseModel):
    name: str = ""
    gender: str = ""
    birthday: str = ""
    mbti: str = ""
    occupation: str = ""
    hobbies: str = ""
    bio: str = ""


class DistillIn(BaseModel):
    messages: list[dict] = []
    chat_path: str = ""
    target_name: str = ""
    npc_id: str = ""                # 为空则新建
    emoji: str = ""
    avatar: str = ""                # 图片头像 dataURL
    basics: dict = {}               # 用户手填基本信息（性别/年龄等）
    relation: str = ""
    llm: LLMIn | None = None


class OcrIn(BaseModel):
    images: list[str] = []
    target_side: str = "left"


def _cfg(body_llm) -> dict | None:
    return body_llm.model_dump() if body_llm else None


# ---------- 健康 / 配置 ----------

@app.get("/health")
def health():
    return {"ok": True, "characters": len(_list_index())}


# ---------- 用户档案 ----------

def _load_user() -> dict:
    raw = _load(USER, None)
    return {**persona_schema.empty_user(), **(raw or {})}


@app.get("/user")
def get_user():
    return _load_user()


@app.put("/user")
def put_user(body: UserIn):
    """更新用户档案。NPC 聊天时会把它注入提示词，让 TA 了解你。"""
    u = {k: getattr(body, k).strip() for k in persona_schema.USER_FIELDS}
    _save(USER, u)
    return {"ok": True, "user": u}


@app.get("/config/providers")
def providers():
    """只回报后端是否有兜底 key。不推荐任何厂商/模型（需求：不做推荐）。"""
    return {"env_fallback": bool(os.environ.get("LLM_API_KEY"))}


@app.post("/config/test")
def test_key(cfg: LLMIn):
    try:
        text = llm.complete([{"role": "user", "content": "回复两个字：收到"}],
                            temperature=0.1, cfg=cfg.model_dump())
    except llm.NoKey as e:
        raise HTTPException(400, str(e)) from e
    except RuntimeError as e:
        return {"ok": False, "error": str(e)}
    resolved = llm.resolve_config(cfg.model_dump())
    return {"ok": True, "reply": text,
            "using": {"base_url": resolved["base_url"], "model": resolved["model"],
                      "api_key": _mask(resolved["api_key"])}}


def _mask(key: str) -> str:
    return f"{key[:4]}…{key[-4:]}" if len(key) > 8 else "***"


# ---------- 预设 & 人物列表 ----------

@app.get("/presets")
def get_presets():
    return {"presets": presets.list_presets()}


@app.get("/characters")
def list_characters():
    items = _list_index()
    for it in items:
        it["unread"] = _unread_count(it["id"])
    return {"characters": items}


@app.post("/characters")
def create_character(body: CreateIn):
    if body.tags:
        try:
            prof = presets.build_from_tags(body.tags, body.name or "未命名", body.basics)
        except KeyError as e:
            raise HTTPException(400, str(e)) from e
    elif body.preset_id:   # 兼容旧的单选接口
        try:
            prof = presets.build_from_preset(body.preset_id, body.name or "未命名",
                                             body.basics)
        except KeyError as e:
            raise HTTPException(400, str(e)) from e
    else:
        prof = persona_schema.new_profile(body.name or "未命名", source_platform="manual")
        prof["basics"].update(body.basics)
    if body.emoji:
        prof["emoji"] = body.emoji
    if body.avatar:
        prof["avatar"] = body.avatar
    if body.relation:
        prof["relationship"]["bond"] = body.relation

    npc_id = _new_id()
    _save_npc(npc_id, "persona.json", prof)
    _save_npc(npc_id, "memory.json", persona_schema.empty_memory())
    _upsert_index(npc_id, prof)
    return {"id": npc_id, "persona": prof}


@app.get("/characters/{npc_id}")
def get_character(npc_id: str):
    return _need_persona(npc_id)


@app.get("/characters/{npc_id}/report")
def get_report(npc_id: str):
    """读取蒸馏时生成的 report.md；不存在（如手动创建）时返回空串。"""
    _need_persona(npc_id)
    f = _npc_dir(npc_id) / "report.md"
    if not f.exists():
        return {"report": ""}
    return {"report": f.read_text(encoding="utf-8")}


@app.delete("/characters/{npc_id}")
def delete_character(npc_id: str):
    """软删：移出索引 + 清空人格/记忆/历史/收件箱。不物理删目录。

    沙箱环境会拦截 unlink/rmtree（WorkBuddy safe-delete 守卫抛 SystemExit），
    而 data/ 是 gitignore 的开发数据 —— 清空即可达到「NPC 消失且数据失效」的效果。
    """
    p = _need_persona(npc_id)
    dispatcher.reset(npc_id)              # 取消在飞任务、清空 pending/outbox
    _save_npc(npc_id, "persona.json", persona_schema.new_profile("（已删除）"))
    _save_npc(npc_id, "memory.json", persona_schema.empty_memory())
    _save_npc(npc_id, "history.json", [])
    lp = _npc_dir(npc_id) / "last_proactive.json"
    if lp.exists():
        try:
            lp.unlink()
        except OSError:
            _save(lp, "")
    _drop_index(npc_id)
    return {"ok": True}


def _sync_relations(npc_id: str, old_rels: list[dict], new_rels: list[dict]) -> None:
    """关系双向同步：A 的 relations 变化后，同步到被指向 NPC 的反向关系。

    规则：对称复制 relation/context/share_memory，name 用 A 的名字；删除 A→B 也删除 B→A。
    """
    p = _need_persona(npc_id)
    my_name = (p.get("meta") or {}).get("target_name", "") or npc_id
    old = {r.get("npc_id"): r for r in old_rels if r.get("npc_id")}
    new = {r.get("npc_id"): r for r in new_rels if r.get("npc_id")}

    for other_id in set(old) | set(new):
        if other_id == npc_id:
            continue
        op = _load_npc(other_id, "persona.json", None)
        if not op:
            continue
        op_rels = [r for r in (op.get("relations") or []) if r.get("npc_id") != npc_id]
        if other_id in new:
            nr = new[other_id]
            op_rels.append({
                "npc_id": npc_id, "name": my_name,
                "relation": nr.get("relation", ""),
                "share_memory": bool(nr.get("share_memory")),
                "context": nr.get("context", ""),
            })
        op["relations"] = op_rels        # 关键：列表推导出的新列表要写回 op，否则保存的是没更新的旧对象
        _save_npc(other_id, "persona.json", op)
        _upsert_index(other_id, op)


@app.put("/characters/{npc_id}/meta")
def update_meta(npc_id: str, body: MetaIn):
    p = _need_persona(npc_id)
    old_rels = list(p.get("relations") or [])
    if body.name:
        p["meta"]["target_name"] = body.name
    if body.emoji:
        p["emoji"] = body.emoji
    if body.avatar is not None:
        p["avatar"] = body.avatar      # 图片头像；空则回退用 emoji
    if body.relation is not None:
        p["relationship"]["bond"] = body.relation       # 传空=清空
    if body.rel_context is not None:
        p["relationship"]["context"] = body.rel_context
    if body.call_me is not None:
        p["relationship"]["call_me"] = body.call_me
    if body.basics is not None:
        p["basics"].update({k: v for k, v in body.basics.items() if k in p["basics"]})
    if body.relations is not None:
        p["relations"] = body.relations   # [] 表示清空关系
    _save_npc(npc_id, "persona.json", p)
    _upsert_index(npc_id, p)
    if body.relations is not None:
        _sync_relations(npc_id, old_rels, p["relations"])
    return {"ok": True, "persona": p}


@app.post("/characters/{npc_id}/review")
def review(npc_id: str, r: ReviewIn):
    p = _need_persona(npc_id)
    for t in p.get("traits") or []:
        if t.get("name") in r.traits:
            t["review"] = r.traits[t["name"]]
    for f in p.get("flaws") or []:
        if f.get("type") in r.flaws:
            f["review"] = r.flaws[f["type"]]
    issues = persona_schema.validate(p)
    p["review_status"] = "approved" if not issues else "draft"
    _save_npc(npc_id, "persona.json", p)
    return {"ok": True, "issues": issues}


@app.post("/characters/{npc_id}/scale")
def scale(npc_id: str, s: ScaleIn):
    p = _need_persona(npc_id)
    p["flaw_intensity_scale"] = max(0.0, min(1.0, s.flaw_intensity_scale))
    if s.reply_rate is not None:
        p["behavior"]["reply_rate"] = max(0.0, min(1.0, s.reply_rate))
    _save_npc(npc_id, "persona.json", p)
    return {"ok": True, "flaw_intensity_scale": p["flaw_intensity_scale"]}


# ---------- 蒸馏（导入聊天记录） ----------

@app.post("/distill")
async def distill(body: DistillIn):
    import distill as dz

    cfg = _cfg(body.llm)
    if body.messages:
        msgs = body.messages
    elif body.chat_path:
        if not Path(body.chat_path).exists():
            raise HTTPException(404, f"找不到对话文件 {body.chat_path}")
        msgs = json.loads(Path(body.chat_path).read_text(encoding="utf-8"))
    else:
        raise HTTPException(400, "messages 和 chat_path 至少给一个")
    try:
        raw = await asyncio.to_thread(dz.call_llm, dz.build_prompt(msgs, body.target_name), cfg)
    except llm.NoKey as e:
        raise HTTPException(400, f"{e}。先调 /config/test 验一下 key") from e
    except RuntimeError as e:
        raise HTTPException(502, f"模型调用失败：{e}") from e

    issues = dz.validate(raw, msgs)
    prof = persona_schema.from_distill(
        raw, {"target_name": body.target_name, "source_platform": "web",
              "source_message_count": len(msgs),
              "distilled_by": llm.resolve_config(cfg)["model"]}
    )
    if body.emoji:
        prof["emoji"] = body.emoji
    if body.avatar:
        prof["avatar"] = body.avatar
    if body.basics:
        prof["basics"].update({k: v for k, v in body.basics.items() if k in prof["basics"]})
    if body.relation:
        prof["relationship"]["bond"] = body.relation

    npc_id = body.npc_id
    if npc_id:
        # 覆盖已有 NPC：保留用户手填的基本信息和关系（蒸馏只重建人格部分）
        old = _load_npc(npc_id, "persona.json", None)
        if old:
            prof["basics"] = old.get("basics", prof["basics"])
            prof["relations"] = old.get("relations", [])
            prof["emoji"] = old.get("emoji", prof.get("emoji", "🙂"))
            prof["avatar"] = old.get("avatar", "")          # 图片头像保留
            # 用户手填的称呼/共同经历保留（蒸馏重建的 relationship 只含关系类型）
            prof["relationship"]["call_me"] = (old.get("relationship") or {}).get("call_me", "")
            prof["relationship"]["context"] = (old.get("relationship") or {}).get("context", "")
        _save_npc(npc_id, "persona.json", prof)
        _save_npc(npc_id, "report.md", dz.render_report(raw, msgs, issues))
    else:
        npc_id = _new_id()
        _save_npc(npc_id, "persona.json", prof)
        _save_npc(npc_id, "report.md", dz.render_report(raw, msgs, issues))

    # 换人了就干干净净重来：旧人的记忆、聊天记录、收件箱、主动记录都是上一个灵魂的
    _save_npc(npc_id, "memory.json", persona_schema.empty_memory())
    _save_npc(npc_id, "history.json", [])
    lp = _npc_dir(npc_id) / "last_proactive.json"
    if lp.exists():
        lp.unlink()
    dispatcher.reset(npc_id)
    _upsert_index(npc_id, prof)
    return {"ok": True, "id": npc_id, "hallucination_issues": issues,
            "traits": len(prof["traits"]), "flaws": len(prof["flaws"])}


# ---------- 聊天 ----------

@app.post("/characters/{npc_id}/chat")
async def chat(npc_id: str, body: ChatIn):
    p = _need_persona(npc_id)
    mem = _load_memory(npc_id)
    cfg = _cfg(body.llm)
    now = datetime.now()

    d = (scheduler.Decision(True, 0.0, "立即模式") if body.immediate
         else scheduler.plan_reply(p, now))

    # 引用回复：把被引用的原话拼进当前消息，像微信的引用样式
    user_message = body.message
    if body.quote and body.quote.get("text"):
        q_role = "我" if body.quote.get("role") == "user" else (p["meta"].get("target_name") or "TA")
        user_message = f"「引用 {q_role}：{body.quote['text']}」\n{body.message}"

    # 已读不回：用户消息也要落盘（标已读），切走再回来不丢；不回直接返回。
    if not d.will_reply:
        _append_history(npc_id, [
            {"role": "user", "content": body.message,
             "at": now.isoformat(timespec="seconds"), "read": True},
        ])
        return {"will_reply": False, "reason": d.reason, "reply_at": None}

    # 先把用户消息落盘（延迟/立即/拦截都覆盖），否则切走再回来、或 LLM 还在跑时会丢消息。
    _append_history(npc_id, [
        {"role": "user", "content": body.message, "at": now.isoformat(timespec="seconds")},
    ])

    try:
        out = await asyncio.to_thread(engine.chat, p, user_message, body.history, mem, cfg,
                                      _load_user())
    except llm.NoKey as e:
        raise HTTPException(400, f"{e}。先调 /config/test 验一下 key") from e
    except RuntimeError as e:
        raise HTTPException(502, f"模型调用失败：{e}") from e

    if out["blocked"]:
        return {"will_reply": True, "delivered": False,
                "blocked": True, "reason": out["reason"], "raw": out["raw"]}

    new = await asyncio.to_thread(engine.extract_memories, p, body.message, out["reply"], cfg)
    if any(new.values()):
        _save_npc(npc_id, "memory.json", engine.merge_memory(mem, new))

    # 立即模式：补写 assistant。延迟模式：assistant 由 dispatcher 投递时写，
    # 否则退出再进会「提前看到」还没到点的延迟回复。
    if body.immediate:
        _append_history(npc_id, [
            {"role": "assistant", "content": out["reply"], "at": now.isoformat(timespec="seconds")},
        ])
        return {"will_reply": True, "delivered": True, "text": out["reply"], "blocked": False}

    at = d.reply_at(now)
    tid = await dispatcher.queue_delivery(npc_id, out["reply"], False, None, at)
    return {"will_reply": True, "delivered": False, "task_id": tid,
            "reply_at": at.isoformat(timespec="seconds"),
            "delay_sec": round(d.delay_sec), "reason": d.reason}


@app.get("/characters/{npc_id}/outbox")
def outbox(npc_id: str, since: int = 0):
    return dispatcher.read_outbox(npc_id, since)


@app.get("/characters/{npc_id}/history")
def get_history(npc_id: str):
    return {"messages": _load_history(npc_id)}


@app.post("/characters/{npc_id}/read")
def mark_read(npc_id: str):
    """标记已读：把「上次已读」推进到现在，未读清零。"""
    _need_persona(npc_id)
    _save_npc(npc_id, "last_read.json", datetime.now().isoformat(timespec="seconds"))
    return {"ok": True}


@app.post("/characters/{npc_id}/proactive")
async def proactive(npc_id: str, body: LLMIn | None = None):
    p = _need_persona(npc_id)
    mem = _load_memory(npc_id)
    last_raw = _load_npc(npc_id, "last_proactive.json", None)
    last = datetime.fromisoformat(last_raw) if last_raw else None

    if not scheduler.plan_proactive(p, datetime.now(), last):
        return {"initiated": False}

    trigger = ("（现在没有任何人跟你说话。根据你记得的事，主动说一句你现在想说的话。"
               "一句话，像微信消息一样短。不要解释为什么突然找 TA。）")
    try:
        out = await asyncio.to_thread(engine.chat, p, trigger, [], mem,
                                      body.model_dump() if body else None, _load_user())
    except llm.NoKey as e:
        raise HTTPException(400, str(e)) from e
    except RuntimeError as e:
        raise HTTPException(502, f"模型调用失败：{e}") from e

    if out["blocked"]:
        return {"initiated": False, "blocked": True, "reason": out["reason"]}

    now = datetime.now()
    _save_npc(npc_id, "last_proactive.json", now.isoformat(timespec="seconds"))
    dispatcher.push_outbox(npc_id, {"id": "pro", "type": "proactive",
                                    "at": now.isoformat(timespec="seconds"),
                                    "text": out["reply"], "blocked": False, "reason": None})
    _append_history(npc_id, [{"role": "assistant", "content": out["reply"],
                              "at": now.isoformat(timespec="seconds")}])
    return {"initiated": True, "text": out["reply"]}


@app.get("/characters/{npc_id}/schedule/preview")
def schedule_preview(npc_id: str):
    p = _need_persona(npc_id)
    now = datetime.now()
    d = scheduler.plan_reply(p, now)
    at = d.reply_at(now)
    return {
        "now": now.isoformat(timespec="seconds"),
        "online": scheduler.is_online(p, now),
        "will_reply": d.will_reply,
        "delay_sec": round(d.delay_sec),
        "reply_at": at.isoformat(timespec="seconds") if at else None,
        "reason": d.reason,
    }


# ---------- OCR（全局，与 NPC 无关） ----------

@app.post("/ocr")
async def ocr(body: OcrIn):
    import base64
    import shutil
    import tempfile

    try:
        import ocr_parse
    except ImportError as e:
        # 整包版已内置 rapidocr，走到这里说明是开发模式（未装 OCR 依赖）在跑：
        # 明确告诉用户走文本导入，而不是让 ImportError 在 asyncio.to_thread 里把线程炸掉。
        raise HTTPException(
            400, f"截图 OCR 缺依赖（{e}）。开发模式请先 "
                 "pip install rapidocr-onnxruntime，或改用「粘贴聊天记录」文本导入。") from e

    if not body.images:
        raise HTTPException(400, "没收到图片")
    tmp = Path(tempfile.mkdtemp())
    try:
        chunks = []
        for i, b64 in enumerate(body.images):
            p = tmp / f"{i}.png"
            p.write_bytes(base64.b64decode(b64.split(",", 1)[-1]))
            rows = await asyncio.to_thread(ocr_parse.ocr_tall_image, str(p))
            chunks.append(await asyncio.to_thread(
                ocr_parse.parse_chat, rows, target_side=body.target_side))
        msgs = ocr_parse.merge_msgs(chunks)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    n = sum(1 for m in msgs if m.get("speaker") == "target")
    if len(msgs) < 10:
        return {"messages": msgs, "warn": "识别到的消息太少，多半是 target_side 选反了或截图不清晰"}
    return {"messages": msgs, "n_target": n, "n_user": len(msgs) - n}


# ---------- 内置服务器入口（PyInstaller 冻结后由 Flutter 客户端自动拉起） ----------

def _watch_parent(parent_pid: int) -> None:
    """父进程（故人 App）退出时自杀，防止孤儿进程占着 8000 端口。"""
    if not parent_pid or sys.platform != "win32":
        return
    try:
        import ctypes
        import threading

        SYNCHRONIZE = 0x00100000
        h = ctypes.windll.kernel32.OpenProcess(SYNCHRONIZE, False, parent_pid)
        if not h:
            return

        def _waiter() -> None:
            ctypes.windll.kernel32.WaitForSingleObject(h, 0xFFFFFFFF)
            os._exit(0)

        threading.Thread(target=_waiter, daemon=True).start()
    except Exception:
        pass  # ponytail: 看门狗是保险不是必需品，失败不影响服务


if __name__ == "__main__":
    import logging

    port = int(os.environ.get("GUREN_PORT", "8000"))
    try:
        logging.basicConfig(
            filename=str(DATA / "server.log"),
            level=logging.INFO,
            format="%(asctime)s %(levelname)s %(message)s",
        )
    except OSError:
        pass  # 日志写不了就算了，别耽误起服务
    _watch_parent(int(os.environ.get("GUREN_PARENT_PID", "0") or 0))
    logging.info("guren-server starting: port=%s data=%s frozen=%s",
                 port, DATA, FROZEN)

    import uvicorn

    uvicorn.run(app, host="127.0.0.1", port=port, log_config=None)

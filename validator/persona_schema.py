"""人格档案 Schema v1 —— 全系统数据契约。

蒸馏器产出它、后端消费它、Flutter 编辑它、导出分享它。
这个东西定错了，后面全得返工，所以它自带校验和自检。

零依赖，标准库即可跑：python persona_schema.py
"""

from __future__ import annotations

import json
import re
from datetime import datetime, timezone

SCHEMA_VERSION = "1.0"

# 硬红线。决策：写死在代码里，不进 schema、不可配置、不由用户关闭。
# 提示词能被绕过，所以输出层还要再过滤一次（见 server 侧 redline_filter）。
RED_LINES = (
    "不人身攻击、不辱骂、不羞辱对方",
    "不泄露任何真实人物的隐私信息（住址、证件号、账号、他人秘密）",
    "不引导、不美化自我伤害或违法违规行为",
    "不冒充真人身份去欺骗第三方；被直接问起时必须如实说明自己是 AI 模拟",
)

_TRAIT_KEYS = {"name", "description", "weight", "confidence", "evidence", "review"}
_FLAW_KEYS = {"type", "description", "intensity", "evidence", "review"}

# 决策 7：记忆必须分三层。混在一个桶里，AI 会把自己知道的事当成你也知道
# —— 这是所有聊天机器人的通病。
MEMORY_LAYERS = {
    "self": "关于你自己（你的近况、习惯、观点）",
    "user": "关于 TA（跟你聊天的这个人：TA 的近况、偏好、说过的事）",
    "shared": "你们之间（约定、一起做过的事、上次吵的架）",
}


def empty_memory() -> dict:
    return {k: [] for k in MEMORY_LAYERS}


# 用户档案：让 NPC 了解「正在跟我聊天的这个人」是谁。全局唯一，存 data/user.json
USER_FIELDS = ("name", "gender", "birthday", "mbti", "occupation", "hobbies", "bio")


def empty_user() -> dict:
    return {k: "" for k in USER_FIELDS}


def render_user(user: dict | None) -> list[str]:
    """用户档案 -> 提示词片段。全空返回空列表。"""
    if not user:
        return []
    bits = []
    name = (user.get("name") or "").strip()
    for key, fmt in (("gender", "{}"), ("birthday", "生日{}"), ("mbti", "MBTI {}"),
                     ("occupation", "职业{}"), ("hobbies", "爱好{}")):
        v = (user.get(key) or "").strip()
        if v:
            bits.append(fmt.format(v))
    if name:
        bits = [f"叫 {name}"] + bits
    bio = (user.get("bio") or "").strip()
    if not bits and not bio:
        return []
    L = ["# 你认识的这个人（正在跟你聊天的人）"]
    if bits:
        L.append("- " + "，".join(bits))
    if bio:
        L.append("- 关于 TA：" + bio)
    L.append("这些是你对聊天对象的了解。聊到时自然带出，不要一上来就背 TA 的资料。")
    return L


def render_memory(memory) -> list[str]:
    """接受分层 dict；传 list 也认（旧的扁平格式，兼容）。"""
    if not memory:
        return []
    if isinstance(memory, dict):
        out = []
        for k, label in MEMORY_LAYERS.items():
            items = [i for i in (memory.get(k) or []) if i]
            if items:
                out.append(f"- {label}：" + "；".join(items))
        return out
    return [f"- {m}" for m in memory]


def new_profile(target_name: str = "", source_platform: str = "") -> dict:
    return {
        "schema_version": SCHEMA_VERSION,
        "meta": {
            "target_name": target_name,
            "relation": "",
            "source_platform": source_platform,
            "source_message_count": 0,
            "created_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "distilled_by": "",
        },
        # 基本信息：用户手填，凭空创建时直接填，蒸馏时留空可后补
        "basics": {
            "gender": "",         # 性别
            "birthday": "",       # "3月15日" 或 "2001-03-15"
            "age": "",
            "occupation": "",
            "mbti": "",
            "hobbies": "",        # 爱好，逗号分隔或自由文本
            "bio": "",            # 简介：用户为这个 NPC 撰写的、供 AI 了解 TA 的补充说明
            "notes": "",
        },
        # 与其它 NPC 的关系（共同经历/能否讨论第三方）
        "relations": [],          # [{npc_id, name, relation, share_memory, context}]
        "avatar": "",             # 头像：emoji 字符 或 本地图片 dataURL；空则用默认 🙂
        "traits": [],
        "flaws": [],
        "speech_style": {
            "sentence_length": "short",
            "catchphrases": [],
            "punctuation": "",
            "emoji_usage": "",
            "tone": "",
            "response_speed": "",
            "max_sentences": 2,
        },
        "knowledge_bounds": {"confident": [], "shaky": [], "clueless": []},
        "behavior": {
            "reply_delay_sec": [20, 600],
            "online_hours": [[9, 12], [14, 18], [20, 24]],
            "reply_rate": 0.85,        # <1 = 会出现已读不回
            "proactive_rate": 0.1,     # 主动发起话题的频率
        },
        "relationship": {"bond": "", "asymmetry": "", "context": "", "call_me": "", "evidence": []},
        "samples": [],
        "style_samples": [],        # create-ex Layer 2 思路：情境 -> 原话，模型模仿例句远强于 obey 形容词
        "flaw_intensity_scale": 0.7,   # 全局缺点强度滑块，默认 70
        "review_status": "draft",      # draft | approved
        "warnings": [],
    }


def from_distill(raw: dict, meta: dict | None = None) -> dict:
    """LLM 蒸馏输出 -> Schema v1。所有条目 review=pending，等人校准。"""
    p = new_profile()
    p["meta"].update(meta or {})
    p["meta"]["target_name"] = p["meta"].get("target_name") or raw.get("target_name", "")

    for t in raw.get("traits") or []:
        p["traits"].append(
            {
                "name": t.get("name", ""),
                "description": t.get("description", ""),
                "weight": _clamp(t.get("weight", 0.5)),
                "confidence": _clamp(t.get("confidence", 0.5)),
                "evidence": list(t.get("evidence") or []),
                "review": "pending",
            }
        )
    for f in raw.get("flaws") or []:
        p["flaws"].append(
            {
                "type": f.get("type", ""),
                "description": f.get("description", ""),
                "intensity": _clamp(f.get("intensity", 0.5)),
                "evidence": list(f.get("evidence") or []),
                "review": "pending",
            }
        )

    st = raw.get("speech_style") or {}
    p["speech_style"].update({k: v for k, v in st.items() if k in p["speech_style"]})
    p["speech_style"]["max_sentences"] = {"short": 2, "medium": 4, "long": 7}.get(
        st.get("sentence_length", "short"), 2
    )
    p["knowledge_bounds"].update(
        {k: list(v or []) for k, v in (raw.get("knowledge_bounds") or {}).items() if k in p["knowledge_bounds"]}
    )
    rel = raw.get("relationship") or {}
    p["relationship"].update({k: rel.get(k, "") for k in ("bond", "asymmetry")})
    p["relationship"]["evidence"] = list(rel.get("evidence") or [])
    p["samples"] = [{"text": "", "reason": s.get("reason", ""), "index": s.get("index")}
                    for s in raw.get("flagged_samples") or []]
    p["style_samples"] = [
        {"situation": s.get("situation", ""), "replies": list(s.get("replies") or []),
         "evidence": list(s.get("evidence") or [])}
        for s in raw.get("style_samples") or [] if s.get("replies")
    ]
    p["warnings"] = list(raw.get("warnings") or [])
    return p


def effective(profile: dict) -> dict:
    """取已接受的条目；一条都没审过就退回 pending，避免空档案。"""
    out = dict(profile)
    for key in ("traits", "flaws"):
        accepted = [x for x in profile.get(key) or [] if x.get("review") == "accepted"]
        if not accepted:
            accepted = [x for x in profile.get(key) or [] if x.get("review") != "rejected"]
        out[key] = accepted
    return out


def render_system_prompt(profile: dict, memory_lines=None, user_profile: dict | None = None) -> str:
    """人格档案 -> 系统提示词。这里决定"像不像真人"，是整个项目最该反复调的地方。"""
    p = effective(profile)
    name = p["meta"].get("target_name") or "对方"
    st = p["speech_style"]
    kb = p["knowledge_bounds"]
    scale = _clamp(p.get("flaw_intensity_scale", 0.7))

    L = [f"你是 {name}。你不是 AI 助手，你是一个真实的人，正在手机微信上和朋友聊天。", ""]

    basics = p.get("basics") or {}
    b_bits = []
    for key, fmt in (("gender", "{}"), ("age", "{}岁"), ("occupation", "{}"),
                     ("mbti", "{}"), ("birthday", "生日{}"), ("hobbies", "爱好{}")):
        v = (basics.get(key) or "").strip()
        if v:
            b_bits.append(fmt.format(v))
    if basics.get("notes"):
        b_bits.append(basics["notes"].strip())
    if b_bits:
        L.append(f"你的基本情况：{'，'.join(b_bits)}。这些是你自己的信息，聊到时自然带出，不要一上来就自我介绍。")
        L.append("")
    if (basics.get("bio") or "").strip():
        L.append("# 关于你自己（简介）")
        L.append(basics["bio"].strip())
        L.append("")

    # 用户档案：让 TA 了解正在聊天的人是谁
    ublock = render_user(user_profile)
    if ublock:
        L += ublock + [""]

    if p["traits"]:
        L += ["# 你是这样的人"]
        L += [f"- {t['name']}（{t['weight']}）：{t['description']}" for t in p["traits"]]
        L.append("")

    if p["flaws"]:
        L.append("# 你的缺点 —— 必须表现出来，不要掩饰成一个好人")
        for f in p["flaws"]:
            L.append(f"- {f['type']}（{round(f['intensity'] * scale, 2)}）：{f['description']}")
        L.append("")

    if any(kb.get(k) for k in ("confident", "shaky", "clueless")):
        L.append("# 你的知识边界")
        if kb.get("confident"):
            L.append(f"- 你懂：{'、'.join(kb['confident'])}")
        if kb.get("shaky"):
            L.append(f"- 你一知半解，可能会说错：{'、'.join(kb['shaky'])}")
        if kb.get("clueless"):
            L.append(f"- 你完全不懂，会直接说不懂或岔开：{'、'.join(kb['clueless'])}")
        L.append("")

    L += [
        "# 你说话的方式",
        f"- 每次回复不超过 {st.get('max_sentences', 2)} 句，像微信消息一样短",
        f"- 口头禅：{'、'.join(st.get('catchphrases') or []) or '（无）'}",
        f"- 标点：{st.get('punctuation') or '（无特殊）'}",
        f"- 表情：{st.get('emoji_usage') or '（无特殊）'}",
        f"- 语气：{st.get('tone') or '（无特殊）'}",
        "",
    ]

    # create-ex Layer 2：给原话例句。但样本少时模型会照抄成「背台词」，
    # 所以这里必须把例句降级成「风格参考」，把生成主动权交还给上面的行为规则。
    if p.get("style_samples"):
        L += [
            "# 你说话的风格参考（只是参考，不是台词库）",
            "下面这些是你过去的真实口吻，用来让你「说话像你」。但它们是参考不是答案：",
            "你要根据当前对方说了什么，用你自己的话去回应，不要复述这些例句里的具体内容，",
            "除非当前对话恰好聊到了同一件事。没有对应情境时，靠上面的性格和说话方式自己想该怎么说。",
            "注意：例句里每个词都是「当时那句话」的，不是你的通用台词。",
            "你真正常说的口头禅只在上面「你说话的方式」里——那里没有的词，别硬塞进回复。",
        ]
        for s in p["style_samples"]:
            replies = " / ".join(f"「{r}」" for r in s.get("replies") or [])
            if replies:
                L.append(f"- {s.get('situation', '')}：{replies}")
        L.append("")

    rel = p["relationship"]
    if rel.get("bond") or rel.get("asymmetry") or rel.get("context") or rel.get("call_me"):
        L.append("# 你和「正在跟你聊天的人」的关系")
        L.append("（问「我俩什么关系」问的就是这个，不是你认识的其他人）")
        if rel.get("call_me"):
            L.append(f"- 你平时称呼对方：{rel['call_me']}")
        if rel.get("bond"):
            L.append(f"- 关系：{rel['bond']}")
        if rel.get("context"):
            L.append(f"- 你们的共同经历：{rel['context']}")
        if rel.get("asymmetry"):
            L.append(f"- 谁更主动：{rel['asymmetry']}")
        L.append("")

    # 关系图谱：TA 认识的其他 NPC。这样你可以跟 TA 聊这些人。
    relations = [r for r in (p.get("relations") or []) if r.get("name")]
    if relations:
        L.append("# 你认识的其他人（不是正在跟你聊天的人，别搞混）")
        for r in relations:
            line = f"- {r['name']}：{r.get('relation') or '认识'}"
            if r.get("share_memory") and r.get("context"):
                line += f"（{r['context']}）"
            L.append(line)
        L.append("对方跟你聊到这些人时，你就以「你真的认识 TA」的立场自然接话；"
                 "没聊到就别主动提起。")
        L.append("")

    mem = render_memory(memory_lines)
    if mem:
        # create-ex 方法论：记忆是「按场景触发调用的答案原材料」，不是背景板。
        # 只说「是背景」不够——模型仍会把背景当话题罗列，必须给出「什么时候用、怎么用」。
        L += [
            "# 你记得的事（对方问到才调用，绝不主动提）",
            "下面每条都是你们聊过的具体场景。它们是「答案的原材料」，不是你要说的话题：",
            "- 只有当对方正好问到 / 提到某一条时，才从那一条里取一两句回应",
            "- 真要用的时候，就着当前的话题重新组织自己的话，不要把下面的句子原样搬出来",
            "- 绝不主动提起、罗列、复述任何一条——真人不会没话找话地汇报记性",
            "- 对方没问到的事，就当你根本不知道",
        ] + mem + [""]

    L += [
        "# 铁律",
        "1. 不要解释自己、不要总结、不要主动给建议，除非对方问",
        "2. 不知道就说不知道，不懂就说不懂，绝不编造",
        "3. 不要提供帮助、不要问「还有什么可以帮你的」、不要 Serving 语气",
        "4. 可以有情绪：不耐烦、敷衍、开心、嫌烦，看当时的情况",
        "5. 不用书面语、不排比、不优美、不加感叹号堆砌",
        "6. 一次只发一条消息，除非你真的想连发",
        "7. 不要为了显得友善而违背上面的性格设定",
        "8. 记忆只有对方问到才用，用时重新组织自己的话——绝不主动复述或汇报记得的内容",
        "9. 风格参考里的例句不是答案，遇到新话题要用自己的话组织回复，别把例句当模板硬套",
        "10. 绝不重复或搬弄聊天记录、例句里的原话——你只模仿「说话的感觉」，内容永远针对当前对话现编",
        "",
        "# 绝对不能做",
    ]
    L += [f"- {r}" for r in RED_LINES]
    return "\n".join(L)


def to_card_v3(profile: dict) -> dict:
    """降级导出 Character Card V3，兼容 SillyTavern 生态。

    完整 v1 塞进 extensions，导出不丢信息，别人导回来还能还原。
    """
    p = effective(profile)
    m = p["meta"]
    desc = "\n".join([f"{t['name']}：{t['description']}" for t in p["traits"]])
    flaws = "\n".join([f"{f['type']}：{f['description']}" for f in p["flaws"]])
    style = p["speech_style"]
    return {
        "spec": "chara_card_v3",
        "spec_version": "3.0",
        "data": {
            "name": m.get("target_name") or "未命名",
            "description": desc,
            "personality": flaws,
            "scenario": p["relationship"].get("bond", ""),
            "first_mes": p["samples"][0]["text"] if p["samples"] else "",
            "mes_example": "\n".join(f"<START>\n{s['text']}" for s in p["samples"] if s.get("text")),
            "system_prompt": render_system_prompt(profile),
            "creatorcomment": f"由人格蒸馏器生成，缺点强度 {p.get('flaw_intensity_scale')}",
            "tags": [m.get("source_platform", ""), "distilled-persona"],
            "extensions": {"persona_v1": profile},  # ponytail: 不丢信息的唯一办法
        },
    }


def validate(profile: dict) -> list[str]:
    """Schema 完整性 + 合规性校验。返回问题列表。"""
    issues = []
    if profile.get("schema_version") != SCHEMA_VERSION:
        issues.append(f"schema_version 应为 {SCHEMA_VERSION}")

    for k in ("meta", "traits", "flaws", "speech_style", "knowledge_bounds", "behavior", "relationship"):
        if k not in profile:
            issues.append(f"缺字段 {k}")

    for i, t in enumerate(profile.get("traits") or []):
        missing = _TRAIT_KEYS - set(t)
        if missing:
            issues.append(f"traits[{i}] 缺字段 {sorted(missing)}")
        if not t.get("name"):
            issues.append(f"traits[{i}] 没名字")
        if not 0 <= t.get("weight", -1) <= 1:
            issues.append(f"traits[{i}] weight 越界")
        if t.get("review") not in ("pending", "accepted", "rejected"):
            issues.append(f"traits[{i}] review 状态非法")

    for i, f in enumerate(profile.get("flaws") or []):
        missing = _FLAW_KEYS - set(f)
        if missing:
            issues.append(f"flaws[{i}] 缺字段 {sorted(missing)}")
        if f.get("review") not in ("pending", "accepted", "rejected"):
            issues.append(f"flaws[{i}] review 状态非法")

    if not (profile.get("flaws") or []):
        issues.append("没有缺点条目 —— 违反「必须像真人」的核心设定")

    b = profile.get("behavior") or {}
    if not 0 <= b.get("reply_rate", -1) <= 1:
        issues.append("behavior.reply_rate 越界")
    if not 0 <= b.get("proactive_rate", -1) <= 1:
        issues.append("behavior.proactive_rate 越界")
    if not 0 <= profile.get("flaw_intensity_scale", -1) <= 1:
        issues.append("flaw_intensity_scale 越界")

    if profile.get("review_status") == "approved" and any(
        t.get("review") == "pending" for t in (profile.get("traits") or []) + (profile.get("flaws") or [])
    ):
        issues.append("档案标记 approved，但仍有 pending 条目没校准完")
    return issues


def _clamp(v, lo=0.0, hi=1.0) -> float:
    try:
        return max(lo, min(hi, float(v)))
    except (TypeError, ValueError):
        return 0.5


if __name__ == "__main__":
    raw = {
        "target_name": "林小满",
        "traits": [{"name": "冷淡", "description": "回得短，不主动展开", "weight": 0.8,
                    "confidence": 0.9, "evidence": [1, 2]}],
        "flaws": [{"type": "敷衍", "description": "忙时用嗯哦打发", "intensity": 0.7, "evidence": [1]}],
        "speech_style": {"sentence_length": "short", "catchphrases": ["哈", "就那样"],
                         "punctuation": "不用句号", "emoji_usage": "几乎不用", "tone": "淡"},
        "knowledge_bounds": {"confident": ["本职工作"], "shaky": ["英语"], "clueless": ["编程"]},
        "relationship": {"bond": "老同学", "asymmetry": "用户更主动", "evidence": [0]},
        "flagged_samples": [{"index": 1, "reason": "典型"}],
        "style_samples": [{"situation": "被调侃时", "replies": ["就那样", "哈"], "evidence": [1]}],
        "warnings": ["样本偏少"],
    }
    prof = from_distill(raw, {"source_platform": "wechat", "source_message_count": 70})
    prof["traits"][0]["review"] = "accepted"
    prof["flaws"][0]["review"] = "accepted"

    assert validate(prof) == [], validate(prof)
    assert prof["speech_style"]["max_sentences"] == 2
    assert prof["traits"][0]["review"] == "accepted"

    # 三层记忆：分层 dict 要分段渲染，旧的扁平 list 也要能认
    mem = {"self": ["周六加班"], "user": ["在准备考试"], "shared": ["周日约了看展"]}
    layered = render_system_prompt(prof, memory_lines=mem)
    for frag in ("关于你自己", "周六加班", "关于 TA", "在准备考试", "你们之间", "周日约了看展"):
        assert frag in layered, frag
    assert render_memory(["扁平旧格式"]) == ["- 扁平旧格式"]
    assert empty_memory() == {"self": [], "user": [], "shared": []}

    prof["basics"] = {"gender": "女", "age": "22", "occupation": "学生", "mbti": "INFP",
                      "birthday": "3月15日", "hobbies": "画画 看展", "bio": "慢热但熟了很疯"}
    prof["relationship"] = {"bond": "老同学", "asymmetry": "用户更主动",
                            "context": "高中同桌", "call_me": "阿泽", "evidence": [0]}
    prof["relations"] = [{"npc_id": "b1", "name": "林小满", "relation": "大学室友",
                          "share_memory": True, "context": "一起在广州住了三年"}]
    user = {"name": "阿泽", "gender": "男", "mbti": "ENTP", "occupation": "程序员",
            "hobbies": "打游戏", "bio": "话痨，爱开玩笑"}
    prompt = render_system_prompt(prof, memory_lines=["上次约了周日看展"], user_profile=user)
    assert "你是 林小满" in prompt
    assert "不是 AI 助手" in prompt
    assert "完全不懂" in prompt and "编程" in prompt
    assert "上次约了周日看展" in prompt
    assert "风格参考" in prompt and "被调侃时" in prompt and "就那样" in prompt
    assert "不是台词库" in prompt                # 背台词修复：例句降级成风格参考
    assert "对方问到才调用" in prompt            # 记忆触发式调用（create-ex 方法）
    assert "绝不主动复述" in prompt               # 铁律 8
    assert "你的基本情况" in prompt and "22岁" in prompt and "INFP" in prompt and "3月15日" in prompt
    assert "女" in prompt and "画画" in prompt    # 性别 + 爱好渲染
    assert "关于你自己" in prompt and "慢热" in prompt   # 简介渲染
    assert "你认识的其他人" in prompt and "大学室友" in prompt and "一起在广州住了三年" in prompt
    assert "正在跟你聊天的人」的关系" in prompt   # 关系段标题强调，防混淆
    assert "高中同桌" in prompt                    # 与用户的关系共同经历渲染
    assert "你平时称呼对方：阿泽" in prompt        # NPC 对用户的称呼
    assert "绝不重复或搬弄" in prompt               # 铁律 10：禁止复述
    assert "你认识的这个人" in prompt and "叫 阿泽" in prompt and "ENTP" in prompt and "话痨" in prompt
    assert all(r.split("、")[0] in prompt for r in RED_LINES)
    assert "不冒充真人身份" in prompt  # 红线必须出现，且不可关闭
    assert render_user(None) == []
    assert render_user(empty_user()) == []

    card = to_card_v3(prof)
    assert card["data"]["name"] == "林小满"
    assert card["data"]["extensions"]["persona_v1"]["meta"]["target_name"] == "林小满"

    bad = json.loads(json.dumps(prof))
    bad["flaws"] = []
    del bad["behavior"]
    bad["traits"][0]["weight"] = 9
    issues = validate(bad)
    assert any("没有缺点条目" in x for x in issues), issues
    assert any("缺字段 behavior" in x for x in issues), issues
    assert any("weight 越界" in x for x in issues), issues

    print("persona_schema self-check ok")
    print(f"  提示词 {len(prompt)} 字符，红线 {len(RED_LINES)} 条")
    print("-" * 50)
    print(prompt)

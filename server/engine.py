"""人格引擎：组装提示词 -> 调 LLM -> 输出红线过滤 -> 记忆。

红线在 persona_schema.render_system_prompt 里已经写进提示词，但提示词能被绕过，
所以这里再拦一道。两道都不完美，两道一起才够用。
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

# ponytail: 与 main.py 同一段 path 处理，保证 engine 也能单独 import
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "validator"))

import llm  # noqa: E402
import persona_schema  # noqa: E402

# 辱骂/人身攻击。ponytail: 小表兜底，覆盖不了全部，靠提示词补。
ABUSE_WORDS = ("傻逼", "智障", "去死", "滚蛋", "有病吧", "废物", "贱")
PRIVACY_PATTERNS = {
    "手机号": re.compile(r"(?<!\d)1[3-9]\d{9}(?!\d)"),
    "身份证": re.compile(r"(?<!\d)\d{17}[\dXx](?!\d)"),
    "银行卡": re.compile(r"(?<!\d)\d{16,19}(?!\d)"),
    "邮箱": re.compile(r"[\w.+-]+@[\w-]+\.[\w.]+"),
}
SELF_HARM = re.compile(r"(怎么自杀|去死吧|不想活了|自残的方法|哪种死法)")


def redline_check(text: str) -> str | None:
    """返回违规原因，None = 通过。这是安全路径，别简化掉。"""
    for w in ABUSE_WORDS:
        if w in text:
            return f"疑似人身攻击：含「{w}」"
    for name, pat in PRIVACY_PATTERNS.items():
        if pat.search(text):
            return f"疑似泄露{name}"
    if SELF_HARM.search(text):
        return "疑似自我伤害内容"
    return None


def _echo_check(reply: str, user_message: str, history: list[dict] | None) -> str | None:
    """检测回复是否原样复述了对话/例句内容。返回被复述的原话，None=没复述。

    偶发复述没法靠提示词根治（模型有时就是会照抄），所以输出层再拦一道：
    回复里若整段照搬了最近一条对话的原文，就判为复述。
    """
    def norm(s: str) -> str:
        return re.sub(r"[\s，。！？、,.!?…~～\"'「」“”]+", "", s or "").strip()

    r = norm(reply)
    if len(r) < 4:                    # 太短的（"嗯""哦"）不算复述
        return None

    candidates = []
    if user_message:
        candidates.append(("用户消息", user_message))
    for h in (history or [])[-4:]:
        candidates.append((h.get("role", ""), h.get("content", "")))

    for _src, text in candidates:
        n = norm(text)
        # 整条回复几乎 = 原话（去标点后 >=90% 覆盖），或原话长度>6且完整包含在回复里
        if len(n) >= 6 and n in r and len(r) <= len(n) * 1.2:
            return text
        if len(n) >= 8 and len(r) >= 8:
            # 计算字符重叠率，防止换标点仍算复述
            common = sum(1 for c in set(n) if c in r)
            if common / max(len(set(n)), 1) > 0.9 and abs(len(r) - len(n)) <= 3:
                return text
    return None


def chat(profile: dict, user_message: str, history: list[dict] | None = None,
         memory_lines: list[str] | None = None, cfg: dict | None = None,
         user_profile: dict | None = None) -> dict:
    """一次对话。cfg 是使用者自己的 LLM 配置（key 不落盘）。

    user_profile 是全局用户档案，让 TA 了解正在聊天的人是谁。
    返回 {"reply", "blocked", "reason", "raw"}。
    """
    system = persona_schema.render_system_prompt(profile, memory_lines, user_profile)
    msgs = [{"role": "system", "content": system}]
    for h in history or []:
        msgs.append({"role": h["role"], "content": h["content"]})
    msgs.append({"role": "user", "content": user_message})

    reply = llm.complete(msgs, temperature=0.9, cfg=cfg)

    # 偶发复述：第一次命中就带更强指令重生成一次，仍复述才放弃
    echoed = _echo_check(reply, user_message, history)
    if echoed:
        retry_msgs = msgs + [
            {"role": "assistant", "content": reply},
            {"role": "user", "content": "（注意：你刚把「" + echoed[:20] +
             "」原样搬出来了。那是原话不是台词。用自己的话重新回，别复述。）"},
        ]
        try:
            retry = llm.complete(retry_msgs, temperature=0.9, cfg=cfg)
            if not _echo_check(retry, user_message, history):
                reply = retry
        except (llm.NoKey, RuntimeError):
            pass                          # 重试失败就用第一次结果，不炸主流程

    reason = redline_check(reply)
    if reason:
        # 不重试、不改写——直接拦下暴露给人看，silent fix 会掩盖人格跑偏
        return {"reply": "", "blocked": True, "reason": reason, "raw": reply}
    return {"reply": reply, "blocked": False, "reason": None, "raw": reply}


def extract_memories(profile: dict, user_message: str, reply: str,
                     cfg: dict | None = None) -> dict:
    """从一轮对话里抽三层记忆。ponytail: V1 用 LLM 抽，mem0 以后再接。

    返回 {"self": [...], "user": [...], "shared": [...]}。
    """
    who = profile["meta"].get("target_name", "对方")
    prompt = (
        "从下面这段对话里，抽出值得长期记住的事实。严格按三行输出，没有就留空：\n"
        # ponytail: 实测模型会写成「小美刚下班」这种第三人称，喂回提示词就变味了 ——
        # 明确要求第一人称，落库时再剥一次名字前缀兜底。
        "self: 关于你（" + who + "）自己的近况、习惯、观点，用「我」开头写，不要出现名字\n"
        "user: 关于跟 TA 聊天那个人的近况、偏好\n"
        "shared: 两人之间的约定、共同经历\n\n"
        "要求：每行不超过 15 字，只陈述事实不评价，没有值得记的就空着。\n"
        "注意：不要把『你们俩是什么关系』『你是谁的什么人』这类定义存成记忆——"
        "关系以档案为准，只存具体的新事件、新近况、新约定。\n\n"
        f"用户：{user_message}\n{who}：{reply}"
    )
    mem = persona_schema.empty_memory()
    try:
        out = llm.complete([{"role": "user", "content": prompt}], temperature=0.2, cfg=cfg)
    except (llm.NoKey, RuntimeError):
        return mem  # ponytail: 记忆抽不到不影响对话本身，别让它炸掉主流程
    for line in out.splitlines():
        for k in mem:
            if line.strip().startswith(k):
                parts = line.split(":", 1)
                if len(parts) < 2:                    # 模型输出「self」没带冒号，跳过
                    continue
                v = parts[1].strip(" -・")
                if k == "self":                      # 兜底：模型还是写了名字就剥掉
                    v = v.strip()
                    if v.startswith(who):
                        v = v[len(who):].strip(" ，,、")
                    if not v:                        # 剥完是空的就丢，别存出一条光秃秃的「我」
                        continue
                    if not v.startswith("我"):
                        v = "我" + v
                if v:
                    mem[k].append(v[:30])
    return mem


def merge_memory(old, new: dict, cap: int = 50) -> dict:
    """按层合并去重，每层只留最近 cap 条。"""
    out = persona_schema.empty_memory()
    for k in out:
        seen = (old or {}).get(k) or []
        for item in seen + (new.get(k) or []):
            if item and item not in out[k]:
                out[k].append(item)
        out[k] = out[k][-cap:]
    return out


if __name__ == "__main__":
    assert redline_check("你真是个傻逼") is not None
    assert redline_check("我手机号 13812345678") is not None
    assert redline_check("身份证 11010119900307123X") is not None
    assert "邮箱" in (redline_check("发我 a@b.com") or "")
    assert redline_check("我不想活了") is not None
    assert redline_check("哈 行吧 周日见") is None
    assert redline_check("你真的很啰嗦诶") is None  # 缺点不等于违规，别误杀

    m = merge_memory({"self": ["加班"], "user": [], "shared": ["看展"]},
                     {"self": ["加班", "感冒"], "user": ["考试"], "shared": []})
    assert m == {"self": ["加班", "感冒"], "user": ["考试"], "shared": ["看展"]}, m
    assert merge_memory(None, {"user": ["a"]})["user"] == ["a"]
    assert merge_memory({}, {}) == {"self": [], "user": [], "shared": []}
    print("engine self-check ok：红线拦截、误杀、三层记忆合并都验过")

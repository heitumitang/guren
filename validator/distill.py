"""对话流 -> 人格档案草稿（带证据链）+ 防幻觉校验 + 校准报告。"""

from __future__ import annotations

import json

SYSTEM_PROMPT = """你是一个人格分析器，任务是从聊天记录里还原一个人的真实性格画像。

铁律：
1. 每一条结论都必须附 evidence —— 引用对方说过的原话序号。没有证据就不要写，宁可少写。
2. traits 和 flaws 的 evidence 只能引用「对方」说的话，绝不能引用「用户」的话。
   唯一例外是 relationship：关系看的是双方互动（谁更主动要对比两边），可以引用任一方。
3. 不要美化。不要因为他偶尔说了句体贴的话就写"温柔体贴"。请判断这是常态还是偶发。
4. 必须找出缺点。一个没有缺点的人不是真人。找：敷衍、误解、回避、偏见、知识盲区、情绪化、迟到失联。
5. 区分"他是什么样的人"和"他和这个用户是什么关系"。同一个人在不同人面前表现不同。
6. 如果样本量不足以支撑某类判断，写进 warnings，而不是编一条出来。
7. traits/flaws 的 description 必须是行为规则：「在什么情况下，他会怎么做、怎么说」。
   禁止只写形容词。「嘴硬」不合格，「被指出问题先否认，用'不算''意外'强行辩解」才合格。
8. style_samples 的 replies 只能是聊天记录里他真正说过的原话（可以截断），一个字都不许改写或新编。

只输出 JSON，不要任何解释文字、不要 markdown 代码块。"""

OUTPUT_SPEC = """输出严格遵循这个 JSON 结构：
{
  "target_name": "对方称呼，从对话推断",
  "traits": [
    {"name": "特质名，4-8字", "description": "行为规则：在什么情况下会怎么做怎么说，禁止只写形容词",
     "weight": 0.0-1.0, "confidence": 0.0-1.0, "evidence": [消息序号]}
  ],
  "style_samples": [
    {"situation": "情境，如：被调侃时 / 对方分享好消息时 / 对方抱怨时 / 被追问时 / 不想聊时 / 日常打招呼",
     "replies": ["他在这个情境下说过的原话（照抄，可截断）", "另一条原话"],
     "evidence": [消息序号]}
  ],
  "speech_style": {
    "sentence_length": "short|medium|long",
    "catchphrases": ["口头禅或高频句式"],
    "punctuation": "标点习惯，如：不用句号、爱用省略号",
    "emoji_usage": "表情/emoji使用习惯",
    "response_speed": "从对话间隔看出的回复节奏",
    "tone": "整体语气"
  },
  "knowledge_bounds": {
    "confident": ["他明显懂、聊起来自信的领域"],
    "shaky": ["他一知半解、会说错的领域"],
    "clueless": ["他明显不懂、会回避或搞错的领域"]
  },
  "flaws": [
    {"type": "缺点类型", "description": "具体表现",
     "intensity": 0.0-1.0, "evidence": [消息序号]}
  ],
  "relationship": {
    "bond": "他和用户的关系性质",
    "asymmetry": "谁更主动、谁更在意，从回复长度和发起频率判断",
    "evidence": [消息序号]
  },
  "flagged_samples": [
    {"index": 消息序号, "reason": "为什么这条适合当 few-shot 样本"}
  ],
  "warnings": ["样本不足或存疑的地方"]
}"""


def ensure_index(messages: list[dict]) -> list[dict]:
    """给缺「i」的消息按位置补序号（OCR 产物已带，手动/导入的消息可能没有）。"""
    return [{**m, "i": m.get("i", i)} for i, m in enumerate(messages)]


def build_prompt(messages: list[dict], target_name: str | None = None, max_msgs: int = 400) -> str:
    sample = messages[-max_msgs:] if len(messages) > max_msgs else messages
    offset = len(messages) - len(sample)
    lines = []
    for idx, m in enumerate(sample):
        i = m.get("i", offset + idx)
        who = "对方" if m.get("speaker") == "target" else "用户"
        lines.append(f"{i}. [{who}]: {m['text']}")
    head = f"以下是「用户」和「{target_name or '对方'}」的聊天记录，共 {len(sample)} 条。\n"
    if offset:
        head += f"（为控制长度，只取最近 {len(sample)} 条，序号从 {offset} 开始）\n"
    return head + "\n" + "\n".join(lines) + "\n\n" + OUTPUT_SPEC


def call_llm(prompt: str, cfg: dict | None = None) -> dict:
    """cfg 是使用者自己的 LLM 配置；不传就用环境变量兜底。"""
    import llm

    msgs = [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": prompt},
    ]
    try:
        raw = llm.complete(msgs, temperature=0.2, cfg=cfg, json_mode=True)
    except llm.NoKey as e:
        raise SystemExit(f"{e}。也可以先跑 --dry-run 看 prompt") from e

    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        start, end = raw.find("{"), raw.rfind("}")
        if start >= 0 and end > start:
            return json.loads(raw[start : end + 1])
        raise SystemExit(f"模型没返回合法 JSON：\n{raw[:500]}")


def validate(profile: dict, messages: list[dict]) -> list[str]:
    """防幻觉校验，返回问题列表；空列表=通过。"""
    issues = []
    messages = ensure_index(messages)
    n = len(messages)
    idx = {m["i"] for m in messages}
    by_idx = {m["i"]: m for m in messages}

    def check_refs(path: str, refs, allow_user: bool = False):
        """allow_user=True 表示这一项允许引用用户的话（关系看的是双方互动）。"""
        for r in refs or []:
            if r not in idx:
                issues.append(f"{path}: 引用了不存在的消息 #{r}（幻觉）")
            elif by_idx[r]["speaker"] != "target" and not allow_user:
                issues.append(f"{path}: 消息 #{r} 是用户说的，不是对方（证据用错人）")

    for k, t in enumerate(profile.get("traits") or []):
        check_refs(f"traits[{k}]({t.get('name', '?')})", t.get("evidence"))
        if not t.get("evidence"):
            issues.append(f"traits[{k}]({t.get('name', '?')}): 无证据支撑")
        elif len(t["evidence"]) < 2:
            issues.append(f"traits[{k}]({t.get('name', '?')}): 只有 1 条证据，可能是偶发而非性格")

    for k, f in enumerate(profile.get("flaws") or []):
        check_refs(f"flaws[{k}]({f.get('type', '?')})", f.get("evidence"))
    if not profile.get("flaws"):
        issues.append("flaws: 一条缺点都没找到，模型在美化，这份档案不可用")

    # 关系看的是双方互动，允许引用用户的话；traits/flaws 描述「TA 是什么人」，必须只引对方
    check_refs("relationship", (profile.get("relationship") or {}).get("evidence"),
               allow_user=True)
    for k, s in enumerate(profile.get("style_samples") or []):
        check_refs(f"style_samples[{k}]({s.get('situation', '?')})", s.get("evidence"))
        if not s.get("replies"):
            issues.append(f"style_samples[{k}]({s.get('situation', '?')}): 没有原话")
    for s in profile.get("flagged_samples") or []:
        if s.get("index") not in idx:
            issues.append(f"flagged_samples: 引用了不存在的消息 #{s.get('index')}")

    if n < 30:
        issues.append(f"样本仅 {n} 条，低于 30 条，结论可信度很低")
    return issues


def render_report(profile: dict, messages: list[dict], issues: list[str]) -> str:
    """生成人工校准用的 Markdown：每条结论下面挂着原文，人对着看就行。"""
    messages = ensure_index(messages)
    by_idx = {m["i"]: m for m in messages}

    def cites(refs):
        out = []
        for r in refs or []:
            m = by_idx.get(r)
            if m:
                who = "对方" if m["speaker"] == "target" else "用户"
                out.append(f"  - #{r} [{who}] {m['text']}")
        return "\n".join(out) or "  - （无有效引用）"

    L = [f"# 人格档案校准报告 — {profile.get('target_name', '?')}", ""]
    if issues:
        L += ["## ⚠️ 校验问题", ""] + [f"- {x}" for x in issues] + [""]

    L += ["## 人格特质", ""]
    for t in profile.get("traits") or []:
        L += [
            f"### {t.get('name')} — 强度 {t.get('weight')} / 置信 {t.get('confidence')}",
            "",
            t.get("description", ""),
            "",
            "证据：",
            cites(t.get("evidence")),
            "",
        ]

    L += ["## 缺点", ""]
    for f in profile.get("flaws") or []:
        L += [
            f"### {f.get('type')} — 强度 {f.get('intensity')}",
            "",
            f.get("description", ""),
            "",
            "证据：",
            cites(f.get("evidence")),
            "",
        ]

    st = profile.get("speech_style") or {}
    L += ["## 说话风格", ""]
    L += [f"- {k}: {v}" for k, v in st.items()] + [""]

    if profile.get("style_samples"):
        L += ["## 你会这么说（原话样本）", ""]
        for s in profile["style_samples"]:
            L.append(f"### {s.get('situation', '?')}")
            for r in s.get("replies") or []:
                L.append(f"> {r}")
            L += ["", f"证据：", cites(s.get("evidence")), ""]

    kb = profile.get("knowledge_bounds") or {}
    L += ["## 知识边界", ""]
    L += [f"- 懂：{', '.join(kb.get('confident') or []) or '（未识别）'}"]
    L += [f"- 半懂：{', '.join(kb.get('shaky') or []) or '（未识别）'}"]
    L += [f"- 不懂：{', '.join(kb.get('clueless') or []) or '（未识别）'}", ""]

    rel = profile.get("relationship") or {}
    L += ["## 与用户的关系", "", f"- 性质：{rel.get('bond', '')}", f"- 主动性：{rel.get('asymmetry', '')}", ""]

    if profile.get("warnings"):
        L += ["## 模型自己标注的存疑点", ""] + [f"- {w}" for w in profile["warnings"]] + [""]
    return "\n".join(L)


if __name__ == "__main__":
    # 自检：故意埋三类典型幻觉，看 validate 能不能全抓出来
    msgs = [
        {"i": 0, "speaker": "user", "text": "在吗"},
        {"i": 1, "speaker": "target", "text": "哈 什么事"},
        {"i": 2, "speaker": "target", "text": "周六要加班"},
        {"i": 3, "speaker": "target", "text": "就那样 烦死了"},
    ]
    bad = {
        "target_name": "测试对象",
        "traits": [
            {"name": "冷淡", "description": "回得短", "weight": 0.8, "confidence": 0.9, "evidence": [1, 2]},
            {"name": "幻觉特质", "description": "编的", "weight": 0.5, "confidence": 0.5, "evidence": [99]},
            {"name": "用错人", "description": "引了用户的话", "weight": 0.5, "confidence": 0.5, "evidence": [0]},
            {"name": "孤证", "description": "只有一条", "weight": 0.5, "confidence": 0.5, "evidence": [3]},
        ],
        "flaws": [],
        # 关系允许引用用户的话（#0 是用户），不该被判「用错人」
        "relationship": {"bond": "朋友", "asymmetry": "用户更主动", "evidence": [0, 1]},
        "flagged_samples": [{"index": 42, "reason": "不存在"}],
        "style_samples": [{"situation": "被调侃时", "replies": [], "evidence": [99]}],
        "warnings": [],
    }
    issues = validate(bad, msgs)
    joined = "\n".join(issues)
    assert "不存在的消息 #99" in joined, issues
    assert "是用户说的" in joined, issues
    assert "只有 1 条证据" in joined, issues
    assert any("一条缺点都没找到" in x for x in issues), issues
    assert "不存在的消息 #42" in joined, issues
    assert any("style_samples" in x and "没有原话" in x for x in issues), issues
    assert any("style_samples" in x and "#99" in x for x in issues), issues
    assert "低于 30 条" in joined, issues
    # 关系项引用户的话不算错，但 traits 里引就算
    assert not any("relationship" in x and "是用户说的" in x for x in issues), issues
    assert any("traits[2]" in x and "是用户说的" in x for x in issues), issues

    good = {**bad, "traits": [bad["traits"][0]], "flaws": [
        {"type": "敷衍", "description": "常用单字回应", "intensity": 0.7, "evidence": [1, 2]}],
        "flagged_samples": [{"index": 1, "reason": "典型"}],
        "style_samples": [{"situation": "被调侃时", "replies": ["哈 什么事"], "evidence": [1]}]}
    assert validate(good, msgs) == ["样本仅 4 条，低于 30 条，结论可信度很低"], validate(good, msgs)

    rep = render_report(good, msgs, [])
    assert "#1 [对方] 哈 什么事" in rep
    assert "敷衍" in rep
    print("distill self-check ok，抓出幻觉", len(issues), "条")
    for x in issues:
        print("  -", x)

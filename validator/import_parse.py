"""纯文本 / CSV 聊天导出 -> 对话流。

截图 OCR 一次只能拿几十条，导出能拿几千条。这个模块负责把别人导出的文本吃进来，
输出和 OCR 完全一样的格式：[{"i","speaker","text"}]，蒸馏器不用区分来源。

支持三种导出行式（都是市面导出工具实际会写出来的样子）：
    2023-05-01 12:30:00 张三      消息在下面几行
    张三 2023-05-01 12:30:00
    [2023-05-01 12:30] 张三
CSV 按表头猜列：发送人 / 内容。
"""

from __future__ import annotations

import csv
import json
import re

TIME = r"\d{4}[-/年]\d{1,2}[-/月]\d{1,2}[日]?\s+\d{1,2}:\d{2}(?::\d{2})?"
# 时间在前或在后，昵称取另一半；昵称可能带空格，所以只排掉明显的时间串
HEADER_RE = re.compile(
    rf"^\s*[\[（(]?\s*({TIME})\s*[\]）)]?\s*[:\-]?\s*(.+?)\s*$"
    rf"|^\s*(.+?)\s+[\[（(]?({TIME})[\]）)]?\s*$"
)
# 导出里常见的系统提示，跟 OCR 那边共用一套判断
NOISE_RE = re.compile(
    r"(以上是打招呼的内容|你已添加了|现在可以开始聊天了|撤回了一条消息|"
    r"开启了朋友验证|消息已发出，但被对方拒收|拍了拍|领取了你的红包|"
    r"语音通话|视频通话|对方已读)"
)
SEND_COLS = ("发送人", "发言人", "说话人", "昵称", "sender", "speaker", "from", "talker")
TEXT_COLS = ("内容", "消息", "正文", "消息内容", "content", "message", "msg", "text")


def _pick(headers: list[str], candidates: tuple[str, ...]) -> int:
    for i, h in enumerate(headers):
        hl = h.strip().lower()
        if any(c in hl for c in candidates):
            return i
    return -1


def parse_csv(text: str, me: tuple[str, ...] = ()) -> list[dict]:
    rows = list(csv.reader(text.splitlines()))
    if not rows:
        return []
    head = rows[0]
    si, ti = _pick(head, SEND_COLS), _pick(head, TEXT_COLS)
    if si < 0 or ti < 0:   # 没有表头就别猜了，猜错比不猜更糟
        return []
    out = []
    for r in rows[1:]:
        if len(r) <= max(si, ti) or not r[ti].strip():
            continue
        who = r[si].strip()
        out.append({"speaker": "user" if who in me else "target", "text": r[ti].strip()})
    return out


def parse_plain(text: str, me: tuple[str, ...] = ()) -> list[dict]:
    """按「时间 + 昵称」的抬头行切分，抬头之间的行都算这条消息的内容。"""
    out: list[dict] = []
    cur: dict | None = None

    def flush():
        # ponytail: 导出常在消息之间插空行，不剥掉的话每条消息都拖个尾巴
        if cur:
            cur["text"] = cur["text"].strip()
            if cur["text"] and not NOISE_RE.search(cur["text"]):
                out.append(cur)

    for line in text.splitlines():
        m = HEADER_RE.match(line)
        if m:
            flush()
            who = (m.group(2) or m.group(3) or "").strip(" ：:-")
            cur = {"speaker": "user" if who in me else "target", "text": ""}
            continue
        if cur is None:
            continue          # 抬头之前的杂项（导出工具的文件头）一律丢
        cur["text"] += ("\n" if cur["text"] else "") + line.rstrip()
    flush()

    for i, m in enumerate(out):
        m["i"] = i
    return out


def load_any(path: str, me: tuple[str, ...] = ()) -> list[dict]:
    """按扩展名分派。json = 已经是对话流（OCR 的产物）。"""
    with open(path, encoding="utf-8") as f:
        raw = f.read()
    if path.lower().endswith(".json"):
        data = json.loads(raw)
    elif path.lower().endswith(".csv"):
        data = parse_csv(raw, me)
    else:
        data = parse_plain(raw, me)
    for i, m in enumerate(data):
        m.setdefault("i", i)
        m.setdefault("speaker", "target")
        m.setdefault("text", "")
    return data


if __name__ == "__main__":
    sample = """聊天记录导出
=====================
2023-05-01 12:30:00 小美
在吗
刚考完
2023-05-01 12:31:20 1874
在
考得咋样
2023-05-01 12:32:00 小美
别问
问就是凉了
2023-05-01 12:33:00 小美
你已添加了对方，现在可以开始聊天了
"""
    got = parse_plain(sample, me=("1874",))
    assert [m["speaker"] for m in got] == ["target", "user", "target"], got
    assert got[0]["text"] == "在吗\n刚考完", got          # 同一个人多行合并
    assert "撤回" not in "".join(m["text"] for m in got)
    assert "现在可以开始聊天" not in "".join(m["text"] for m in got), got
    assert "聊天记录导出" not in "".join(m["text"] for m in got), got   # 文件头丢弃

    csvtext = "时间,发送人,内容\n2023-05-01,小美,哈哈\n2023-05-01,1874,笑什么\n"
    c = parse_csv(csvtext, me=("1874",))
    assert [(m["speaker"], m["text"]) for m in c] == [("target", "哈哈"), ("user", "笑什么")], c
    assert parse_csv("a,b\n1,2\n", me=()) == []          # 猜不出列就不猜
    print("import_parse self-check ok:", json.dumps(got, ensure_ascii=False))

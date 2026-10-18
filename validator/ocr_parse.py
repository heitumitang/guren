"""聊天截图 -> 对话流：按气泡颜色判边，输出 {"i","speaker","text"} 统一格式。"""

from __future__ import annotations

import json
import re

# 时间戳 / 系统提示 / 无关 UI 文本，一律丢弃。全角冒号、月日格式都要认，
# 分隔符可能写作 12:54 / 12-54 / 12：54（OCR 常把冒号认成连字符）。
TIME_RE = re.compile(
    r"^(\d{1,2}[:：\-－]\d{2}|上午\s*\d{1,2}[:：\-－]\d{2}|下午\s*\d{1,2}[:：\-－]\d{2}|"
    r"昨天\s*[\d:：\-－]+|星期[一二三四五六日]\s*[\d:：\-－]+|"
    r"\d{1,2}月\d{1,2}日[\s\d:：\-－]*)$"
)
SYSTEM_RE = re.compile(
    r"(以上是打招呼的内容|你已添加了|现在可以开始聊天了|撤回了一条消息|"
    r"开启了朋友验证|消息已发出，但被对方拒收|对方正在输入|拍了拍|"
    r"领取了你的红包|通过.*添加|语音通话|视频通话|对方已读)"
)

# 群聊里气泡上方会显示昵称，OCR 会把它并进正文。两种形态都要剥：
#   「邱爱（环境监测）：…」带群备注括号   /   「1874：…」纯数字昵称
NICK_RE = re.compile(
    r"^\s*(?:"
    r"[^\s，。！？、：:]{1,12}[（(][^）)]{1,12}[)）]\s*[：:]?"   # 带（备注）
    r"|[A-Za-z0-9_.·]{1,12}\s*[：:]"                          # 数字/字母昵称
    r")"
)


def strip_label(text: str) -> tuple[str, str | None]:
    """剥掉行首的昵称前缀，返回 (正文, 昵称 or None)。正文里的冒号不受影响。"""
    m = NICK_RE.match(text)
    if not m:
        return text.strip(), None
    return text[m.end():].strip(), m.group(0).rstrip("：:").strip()


def _is_noise(text: str) -> bool:
    t = text.strip()
    if not t:
        return True
    if TIME_RE.match(t) or SYSTEM_RE.search(t):
        return True
    # 纯标点 / 纯数字的 OCR 残渣。注意「嗯」「哦」「好」这种单字是真回复，必须留。
    return not re.search(r"[^\W\d_]", t, re.UNICODE)


def _bubble_side(arr, r: dict) -> str:
    """用气泡边缘颜色判断这一行属于谁。

    微信约定：绿=自己(right)、白=对方(left)、灰=背景(时间戳/居中文字)、其它=图片。
    """
    H, W = arr.shape[:2]
    cy = min(max(int(r["cy"]), 0), H - 1)
    x0, x1 = int(r["x0"]), int(r["x1"])
    pts = [arr[cy, max(0, x0 - 14)], arr[cy, min(W - 1, x1 + 14)],
           arr[cy, max(0, x0 - 24)], arr[cy, min(W - 1, x1 + 24)]]

    def green(p): return p[1] > 185 and 110 < p[0] < 205 and p[2] < 170
    def white(p): return p[0] > 240 and p[1] > 240 and p[2] > 240
    def gray(p):  return 225 <= p[0] <= 250 and max(p) - min(p) < 14

    if any(green(p) for p in pts):
        return "right"
    if any(white(p) for p in pts):
        return "left"
    if all(gray(p) for p in pts):
        return "float"     # 落在背景灰上：时间戳 / 居中提示
    return "image"         # 彩色照片背景：梗图 / 表情包里的文字


def ocr_tall_image(path: str, chunk_h: int = 1600, overlap: int = 90,
                   skip_top: int = 150) -> list[dict]:
    """长截图切块 OCR，加回 y 偏移再合并。skip_top 丢弃顶部状态栏+标题栏。"""
    try:
        import numpy as np
        from PIL import Image
        from rapidocr_onnxruntime import RapidOCR
    except ImportError:
        raise SystemExit("缺依赖：pip install pillow numpy rapidocr-onnxruntime")

    img = Image.open(path).convert("RGB")
    arr = np.array(img)
    W, H = img.size
    ocr = RapidOCR()
    rows = []
    y = 0
    while y < H:
        bottom = min(H, y + chunk_h)
        result, _ = ocr(arr[y:bottom])
        for box, text, score in result or []:
            text = text.strip()
            score = float(score)  # RapidOCR 返回的是字符串，转 float
            if not text or score < 0.45:
                continue
            xs = [p[0] for p in box]
            ys = [p[1] for p in box]
            row = {"text": text, "cx": sum(xs) / len(xs),
                   "cy": sum(ys) / len(ys) + y, "x0": min(xs), "x1": max(xs)}
            if row["cy"] < skip_top:
                continue
            row["side"] = _bubble_side(arr, row)
            rows.append(row)
        if bottom >= H:
            break
        y = bottom - overlap

    rows.sort(key=lambda r: r["cy"])
    out = []
    for r in rows:  # 块与块重叠区会产生重复行，同文+纵坐标接近去重
        if out and r["text"] == out[-1]["text"] and abs(r["cy"] - out[-1]["cy"]) < overlap:
            continue
        out.append(r)
    return out


def parse_chat(rows: list[dict], target_side: str = "left", width: float | None = None) -> list[dict]:
    """OCR 行 -> 对话流。优先用颜色判边，判不出来才退回中线启发式。

    target_side: 目标人物（你要蒸馏的 TA）的气泡在哪一侧。
    """
    usable = []
    n_quotes = 0
    for r in rows:
        if r.get("side") == "image":   # 梗图/表情包里的字不是人话
            continue
        t, name = strip_label(r["text"])
        if name and not t:
            continue                   # 群聊昵称标签行（内容在下一行），整行丢
        if name and r.get("side") == "float":
            # 引用卡片：前缀是被引用的人不是回话人，靠位置归属会张冠李戴 —— 丢
            n_quotes += 1
            continue
        if _is_noise(t):
            continue
        usable.append(dict(r, text=t))
    if n_quotes:
        print(f"（丢弃 {n_quotes} 条引用卡片，避免张冠李戴）")
    if not usable:
        return []

    # 用最大右边界当图宽兜底，判边失败才用它
    mid = (width if width else max(r["x1"] for r in usable)) / 2

    msgs: list[dict] = []
    for r in usable:
        side = r.get("side")
        if side not in ("left", "right"):
            side = "left" if r["cx"] < mid else "right"
        speaker = "target" if side == target_side else "user"
        prev = msgs[-1] if msgs else None
        # 同一个人连续、且纵向靠近的行 = 同一个气泡换行，合并
        if prev and prev["speaker"] == speaker and abs(r["cy"] - prev["_cy"]) < 40:
            prev["text"] += r["text"]
            prev["_cy"] = r["cy"]
        else:
            msgs.append({"speaker": speaker, "text": r["text"], "_cy": r["cy"]})

    for i, m in enumerate(msgs):
        m["i"] = i
        del m["_cy"]
    return msgs


def merge_msgs(chunks: list[list[dict]], max_overlap: int = 500) -> list[dict]:
    """合并多张截图的对话流，去掉滚动截图重叠部分（最长匹配去重）。"""
    merged: list[dict] = []
    for chunk in chunks:
        if not chunk:
            continue
        if merged:
            k = 0
            for size in range(min(max_overlap, len(chunk), len(merged)), 0, -1):
                if [_s(m) for m in merged[-size:]] == [_s(c) for c in chunk[:size]]:
                    k = size
                    break
            chunk = chunk[k:]
        merged += chunk
    for i, m in enumerate(merged):
        m["i"] = i
    return merged


def _s(m: dict) -> tuple[str, str]:
    return (m.get("speaker", ""), (m.get("text") or "").strip())


def load_chat(path: str) -> list[dict]:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    for i, m in enumerate(data):
        m.setdefault("i", i)
    return data


if __name__ == "__main__":
    demo = [
        {"text": "在吗", "cx": 60, "cy": 100, "x0": 40, "x1": 120, "side": "left"},
        {"text": "下午 3:20", "cx": 180, "cy": 130, "x0": 150, "x1": 220, "side": "float"},
        {"text": "刚看到手机", "cx": 400, "cy": 160, "x0": 340, "x1": 520, "side": "right"},
        {"text": "怎么啦", "cx": 410, "cy": 190, "x0": 340, "x1": 480, "side": "right"},
        {"text": "梗图里的字", "cx": 300, "cy": 300, "x0": 260, "x1": 340, "side": "image"},
        {"text": "你已添加了对方，现在可以开始聊天了", "cx": 180, "cy": 40, "x0": 60, "x1": 320, "side": "float"},
        # 真实截图踩过的坑
        {"text": "7月14日12-54", "cx": 180, "cy": 420, "x0": 150, "x1": 220, "side": "float"},
        # 引用卡片：float 底 + 「原作者：原话」。三条都要整条丢，正文也不能留 —— 归属会反。
        {"text": "小美（环境监测）：到时候成绩出来告诉我一声", "cx": 348, "cy": 460, "x0": 125, "x1": 571, "side": "float"},
        {"text": "1874：照照镜子吧", "cx": 220, "cy": 620, "x0": 125, "x1": 340, "side": "float"},
        {"text": "邱爱玻（环境监测）暑假减肥", "cx": 407, "cy": 780, "x0": 234, "x1": 581, "side": "float"},
        {"text": "嗯", "cx": 60, "cy": 900, "x0": 40, "x1": 60, "side": "left"},   # 单字真回复，不能当噪音丢了
        {"text": "。。", "cx": 60, "cy": 940, "x0": 40, "x1": 60, "side": "left"},  # 纯标点，丢
    ]
    # 滚动截图重叠：第二段开头重复了第一段末尾两条，必须去掉
    a = [{"speaker": "target", "text": "甲"}, {"speaker": "user", "text": "乙"},
         {"speaker": "target", "text": "丙"}]
    b = [{"speaker": "user", "text": "乙"}, {"speaker": "target", "text": "丙"},
         {"speaker": "target", "text": "丁"}]
    assert [m["text"] for m in merge_msgs([a, b])] == ["甲", "乙", "丙", "丁"], merge_msgs([a, b])
    assert [m["i"] for m in merge_msgs([a, b])] == [0, 1, 2, 3]
    assert merge_msgs([[], a]) == [{"speaker": "target", "text": "甲", "i": 0},
                                   {"speaker": "user", "text": "乙", "i": 1},
                                   {"speaker": "target", "text": "丙", "i": 2}]
    got = parse_chat(demo, target_side="left", width=560)
    assert [m["speaker"] for m in got[:2]] == ["target", "user"], got
    assert got[1]["text"] == "刚看到手机怎么啦", got  # 同气泡换行合并
    assert all("现在可以开始聊天" not in m["text"] for m in got)
    assert all("梗图" not in m["text"] for m in got)        # 图片文字被丢弃
    assert all("下午 3:20" not in m["text"] for m in got)
    assert all("7月14日" not in m["text"] for m in got)      # 时间戳（连字符形态）
    texts = [m["text"] for m in got]
    assert "嗯" in texts, texts                               # 单字回复保住
    assert "。。" not in texts, texts                         # 纯标点丢掉
    assert not any("邱爱" in t or "1874" in t for t in texts), texts
    assert "到时候成绩出来告诉我一声" not in texts, texts       # 引用卡片整条丢（不留给回话人）
    assert "照照镜子吧" not in texts, texts
    assert "暑假减肥" not in texts, texts
    print("ocr_parse self-check ok:", json.dumps(got, ensure_ascii=False, indent=1))

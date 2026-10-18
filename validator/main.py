"""人格蒸馏验证器 CLI。

    python main.py ocr shot1.png shot2.png -o chat.json
    python main.py distill chat.json --dry-run
    python main.py distill chat.json -o profile.json --report report.md
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

import distill
import import_parse
import llm
import ocr_parse

# load_env 统一放在 llm.py，后端和 CLI 共用一份实现
load_env = llm.load_env


def cmd_ocr(a) -> None:
    # 每张图单独解析再合并：滚动截图之间有重叠，merge_msgs 会把重复那段去掉
    chunks = []
    for img in a.images:
        rows = ocr_parse.ocr_tall_image(img)  # 长截图切块，短图就是单块
        chunks.append(ocr_parse.parse_chat(rows, target_side=a.target_side, width=a.width))
        print(f"  {img}: {len(chunks[-1])} 条")
    msgs = ocr_parse.merge_msgs(chunks)
    Path(a.out).write_text(json.dumps(msgs, ensure_ascii=False, indent=1), encoding="utf-8")
    n_target = sum(1 for m in msgs if m["speaker"] == "target")
    print(f"{len(msgs)} 条（对方 {n_target} / 用户 {len(msgs) - n_target}） -> {a.out}")
    for m in msgs[:8]:
        print(f"  #{m['i']} [{'对方' if m['speaker'] == 'target' else '用户'}] {m['text']}")
    if n_target < 10:
        print("警告：对方发言太少，多半是 --target-side 搞反了或时间戳没滤干净")


def cmd_import(a) -> None:
    """把别人导出的文本/CSV 转成对话流，跟 OCR 产物同格式。"""
    me = tuple(x.strip() for x in (a.me or "").split(",") if x.strip())
    msgs = import_parse.load_any(a.file, me)
    Path(a.out).write_text(json.dumps(msgs, ensure_ascii=False, indent=1), encoding="utf-8")
    n_target = sum(1 for m in msgs if m["speaker"] == "target")
    print(f"{len(msgs)} 条（对方 {n_target} / 用户 {len(msgs) - n_target}） -> {a.out}")
    if not msgs:
        print("一条都没解析出来：检查 --me 填的是不是导出里你自己的昵称，")
        print("或者这个文件的抬头格式不是「时间 + 昵称」（CSV 需要表头含 发送人 / 内容）")
        return
    for m in msgs[:5]:
        print(f"  #{m['i']} [{'对方' if m['speaker'] == 'target' else '用户'}] {m['text'][:40]}")


def cmd_distill(a) -> None:
    me = tuple(x.strip() for x in (a.me or "").split(",") if x.strip())
    msgs = import_parse.load_any(a.chat, me)
    prompt = distill.build_prompt(msgs, a.target)
    if a.dry_run:
        out = a.out or "prompt.txt"  # ponytail: -o 默认 None，避免 dry-run 误写 profile.json
        Path(out).write_text(distill.SYSTEM_PROMPT + "\n\n" + prompt, encoding="utf-8")
        print(f"{len(msgs)} 条对话 -> prompt 已写入 {out}（{len(prompt)} 字符）")
        print("没有 API key 也能验证：把这个 prompt 贴进任意聊天模型，看输出质量")
        return

    profile = distill.call_llm(prompt)
    issues = distill.validate(profile, msgs)
    out = a.out or "profile.json"
    Path(out).write_text(json.dumps(profile, ensure_ascii=False, indent=1), encoding="utf-8")
    Path(a.report).write_text(distill.render_report(profile, msgs, issues), encoding="utf-8")
    print(f"-> {out}\n-> {a.report}")
    print(f"{len(profile.get('traits') or [])} 条特质 / {len(profile.get('flaws') or [])} 条缺点")
    if issues:
        print(f"\n⚠️  {len(issues)} 条校验问题：")
        for x in issues:
            print(f"  - {x}")
    else:
        print("\n校验通过，没有幻觉指控")


def main() -> None:
    load_env()
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("ocr", help="截图 -> 对话流")
    p.add_argument("images", nargs="+")
    p.add_argument("-o", "--out", default="chat.json")
    p.add_argument("--target-side", default="left", choices=["left", "right"])
    p.add_argument("--width", type=float, default=None, help="图宽，气泡只在一侧时手动指定")
    p.set_defaults(func=cmd_ocr)

    p = sub.add_parser("import", help="文本/CSV 导出 -> 对话流（比截图能拿多得多的数据）")
    p.add_argument("file")
    p.add_argument("-o", "--out", default="chat.json")
    p.add_argument("--me", default="", help="导出里你自己叫什么，逗号分隔多个昵称")
    p.set_defaults(func=cmd_import)

    p = sub.add_parser("distill", help="对话流 -> 人格档案")
    p.add_argument("chat")
    p.add_argument("-o", "--out", default=None)
    p.add_argument("--report", default="report.md")
    p.add_argument("--target", default=None)
    p.add_argument("--me", default="", help="非 OCR 来源时，导出里你自己的昵称")
    p.add_argument("--dry-run", action="store_true", help="只生成 prompt，不调 API")
    p.set_defaults(func=cmd_distill)

    a = ap.parse_args()
    a.func(a)


if __name__ == "__main__":
    main()

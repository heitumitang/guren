# validator · 人格蒸馏命令行

不依赖 App，单独把「聊天记录 → 人格档案」这段跑通的工具。App 里的蒸馏接口和它共用同一套提示词、校验与 schema。

## 最快试一下（不需要 API Key）

```bash
python main.py distill samples/chat_sample.json --dry-run
```

会生成 `prompt.txt`，可以贴进任意聊天模型看效果。

## 完整流程

```bash
cp .env.example .env          # 填 LLM_API_KEY

# 路径 A：手上有聊天截图
pip install -r requirements.txt
python main.py ocr shot1.png shot2.png -o chat.json --target-side left
python main.py distill chat.json -o profile.json --report report.md

# 路径 B：有导出的聊天文本 / CSV
python main.py import export.txt -o chat.json --me 你在导出里的昵称
python main.py distill chat.json --target TA的名字 -o profile.json --report report.md
```

`--target-side left` 指白气泡那侧是 TA（微信里对方白、你绿）。TA 的发言少于 10 条会告警，多半是左右搞反了。

`import` 认这些抬头格式：`2023-05-01 12:30:00 昵称`、昵称在前的版本、`[时间] 昵称`；CSV 需要表头含「发送人」和「内容」（也认 sender / content）。`--me` 填你自己的昵称，其余发言者都算 TA。

## 产物结构

| 产物 | 结构 | 谁能吃 |
|---|---|---|
| `distill` 原始输出 | LLM 直出，无 `meta` | 只有 `persona_schema.from_distill()` |
| Schema v1 档案 | 有 `meta` / `behavior`，条目带 `review` | 引擎、`/chat` |

命令行输出的 `profile.json` 是前者，要经 `from_distill()` 转成后者才能拿去聊天（App 的 `/distill` 接口内部已经转好了）。

条目默认是 `pending`，`effective()` 只排除 `rejected` —— 所以蒸馏完立刻就能聊，人工校准是用来剔除不准的条目，不是用来开闸的。

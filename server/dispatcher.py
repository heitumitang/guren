"""常驻调度执行层（多 NPC 版）。

决策 8 的下半身：scheduler 决定「什么时候回」，这里负责「真的到点送到」。

关键设计：**生成和投递分离**。
收到消息就立刻生成回复（此时调用方带着 key），再按调度延迟投递 ——
这样 key 不需要落盘，进程重启后待投递的内容也还在。

多 NPC：outbox/pending 按 NPC 分目录，彼此隔离，不会串线。
"""

from __future__ import annotations

import asyncio
import json
import uuid
from datetime import datetime
from pathlib import Path

DATA = Path(__file__).parent / "data"
CHAR = DATA / "characters"


def _outbox(npc_id: str) -> Path:
    return CHAR / npc_id / "outbox.json"


def _pending(npc_id: str) -> Path:
    return CHAR / npc_id / "pending.json"


def _history(npc_id: str) -> Path:
    return CHAR / npc_id / "history.json"


def _append_history(npc_id: str, entry: dict) -> None:
    """延迟投递的回复在真正送达时才写进历史，避免「还没回却先显示」。"""
    h = _load(_history(npc_id), [])
    h.append(entry)
    _save(_history(npc_id), h[-500:])


def _load(p: Path, default):
    if not p.exists():
        return default
    return json.loads(p.read_text(encoding="utf-8"))


def _save(p: Path, d) -> None:
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(d, ensure_ascii=False, indent=1), encoding="utf-8")


def push_outbox(npc_id: str, item: dict) -> int:
    box = _load(_outbox(npc_id), [])
    box.append(item)
    _save(_outbox(npc_id), box[-300:])
    return max(0, len(box) - 1)


def read_outbox(npc_id: str, since: int = 0) -> dict:
    box = _load(_outbox(npc_id), [])
    return {"total": len(box), "items": box[since:]}


def _drop_pending(npc_id: str, task_id: str) -> None:
    _save(_pending(npc_id), [t for t in _load(_pending(npc_id), []) if t.get("id") != task_id])


# 在飞的投递任务。不跟踪的话 reset() 之后，旧人的定时消息还会落进新人的收件箱。
_tasks: set = set()


def _spawn(task: dict) -> None:
    t = asyncio.create_task(_deliver(task))
    t._npc_id = task.get("npc_id")  # noqa: SLF001 —— reset(npc) 时按这个取消对应 NPC 的任务
    _tasks.add(t)
    t.add_done_callback(_tasks.discard)


async def queue_delivery(npc_id: str, text: str, blocked: bool, reason: str | None,
                         when: datetime) -> str:
    """排一条延迟投递。文本已经生成好了，所以这里不需要 key。"""
    task = {
        "id": uuid.uuid4().hex[:8],
        "npc_id": npc_id,
        "reply_at": when.isoformat(timespec="seconds"),
        "text": text, "blocked": blocked, "reason": reason,
    }
    pending = _load(_pending(npc_id), [])
    pending.append(task)
    _save(_pending(npc_id), pending)
    _spawn(task)
    return task["id"]


async def _deliver(task: dict) -> None:
    delay = (datetime.fromisoformat(task["reply_at"]) - datetime.now()).total_seconds()
    if delay > 0:
        await asyncio.sleep(delay)
    now = datetime.now()
    push_outbox(task["npc_id"], {
        "id": task["id"], "type": "reply",
        "at": now.isoformat(timespec="seconds"),
        "text": task["text"], "blocked": task["blocked"], "reason": task["reason"],
    })
    if not task.get("blocked"):
        # 回复真正送达时才写历史（chat 只在生成时写了 user，避免「没回先显示」）
        _append_history(task["npc_id"], {
            "role": "assistant", "content": task["text"],
            "at": now.isoformat(timespec="seconds"),
        })
    _drop_pending(task["npc_id"], task["id"])


async def restore() -> int:
    """进程重启后把没投递完的任务重新排上。返回恢复条数。"""
    n = 0
    if CHAR.exists():
        for d in CHAR.iterdir():
            for t in _load(_pending(d.name), []):
                _spawn(t)
                n += 1
    return n


def reset(npc_id: str | None = None) -> None:
    """清空指定 NPC（或全部）的在飞投递、待投递和收件箱。"""
    for t in list(_tasks):
        if npc_id is None or t.get_coro() is None or _task_npc(t) == npc_id:
            t.cancel()
            _tasks.discard(t)
    ids = [npc_id] if npc_id else (
        [d.name for d in CHAR.iterdir()] if CHAR.exists() else [])
    for i in ids:
        _save(_pending(i), [])
        _save(_outbox(i), [])


def _task_npc(t) -> str | None:
    """从 asyncio.Task 里取回 npc_id。ponytail: 把 npc_id 挂到 task 属性上最省事。"""
    return getattr(t, "_npc_id", None)


async def _demo() -> None:
    import tempfile

    global CHAR
    CHAR = Path(tempfile.mkdtemp())

    assert read_outbox("a")["total"] == 0
    when = datetime.now().replace(microsecond=0)
    tid = await queue_delivery("a", "哈 行吧", False, None, when)
    await asyncio.sleep(0.4)

    box = read_outbox("a")
    assert box["total"] == 1, box
    assert box["items"][0]["text"] == "哈 行吧"
    assert box["items"][0]["id"] == tid
    assert _load(_pending("a"), []) == [], "投递完 pending 要清空"
    # 另一个 NPC 的收件箱是独立的，不会串线
    assert read_outbox("b")["total"] == 0

    import datetime as _dt
    later = datetime.now().replace(microsecond=0)
    await queue_delivery("a", "等 1 秒", False, None, later + _dt.timedelta(seconds=1))
    assert read_outbox("a")["total"] == 1, "还没到点不该投递"
    await asyncio.sleep(1.3)
    assert read_outbox("a")["total"] == 2, "到点了必须投递"

    await queue_delivery("b", "重启后补发", False, None, later + _dt.timedelta(seconds=60))
    n = await restore()
    assert n == 1, n
    print("dispatcher self-check ok：立即投递、延迟投递、pending 清理、多 NPC 隔离、重启恢复")


if __name__ == "__main__":
    asyncio.run(_demo())

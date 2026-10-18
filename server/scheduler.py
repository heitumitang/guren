"""时间拟人调度决策：给定时刻，决定回不回、什么时候回、会不会主动找用户。"""

from __future__ import annotations

import random
from dataclasses import dataclass
from datetime import datetime, timedelta

DEFAULT_ONLINE = [[9, 12], [14, 18], [20, 24]]
DEFAULT_DELAY = [20, 600]


@dataclass
class Decision:
    will_reply: bool
    delay_sec: float
    reason: str

    def reply_at(self, now: datetime) -> datetime | None:
        return None if not self.will_reply else now + timedelta(seconds=self.delay_sec)


def _behavior(profile: dict) -> dict:
    b = dict(profile.get("behavior") or {})
    b.setdefault("online_hours", DEFAULT_ONLINE)
    b.setdefault("reply_delay_sec", DEFAULT_DELAY)
    b.setdefault("reply_rate", 0.85)
    b.setdefault("proactive_rate", 0.1)
    return b


def is_online(profile: dict, now: datetime) -> bool:
    """在线时段用 [[start_hour, end_hour], ...]。跨天写成两段，如 [20,24] + [0,2]。"""
    return any(s <= now.hour < e for s, e in _behavior(profile)["online_hours"])


def next_online_start(profile: dict, now: datetime) -> datetime | None:
    """下一个开始在线的时刻，找不到就 None（说明该时段配置有问题）。"""
    cands = []
    for s, _ in _behavior(profile)["online_hours"]:
        for day in (0, 1):
            d = (now + timedelta(days=day)).replace(hour=s, minute=0, second=0, microsecond=0)
            if d > now:
                cands.append(d)
    return min(cands) if cands else None


def plan_reply(profile: dict, now: datetime, rng: random.Random | None = None) -> Decision:
    """收到一条消息后，决定回不回、什么时候回。"""
    r = rng or random
    b = _behavior(profile)
    will = r.random() < b["reply_rate"]
    lo, hi = b["reply_delay_sec"]

    if not is_online(profile, now):
        nxt = next_online_start(profile, now)
        if nxt is None:
            return Decision(False, 0.0, "online_hours 配置无效，无法排期")
        # 离线延迟额外抖一次，与在线延迟分布区分
        delay = (nxt - now).total_seconds() + r.uniform(lo, min(hi, 3600))
        reason = f"不在线（现在 {now:%H:%M}），排到 {nxt:%H:%M} 之后"
        return Decision(will, delay, reason if will else reason + "，但已读不回")

    delay = r.uniform(lo, hi)
    return Decision(will, delay, "在线，正常延迟" if will else "在线但已读不回")


def plan_proactive(profile: dict, now: datetime, last_proactive_at: datetime | None,
                   rng: random.Random | None = None) -> bool:
    """TA 会不会主动找你。每小时最多判一次，避免刷屏。"""
    r = rng or random
    b = _behavior(profile)
    if not is_online(profile, now):
        return False
    if last_proactive_at and (now - last_proactive_at) < timedelta(hours=1):
        return False
    return r.random() < b["proactive_rate"]


if __name__ == "__main__":
    # 自检保持零依赖，不引 persona_schema
    prof = {"behavior": {"online_hours": [[9, 12], [14, 18], [20, 24]],
                         "reply_delay_sec": [20, 600],
                         "reply_rate": 1.0, "proactive_rate": 0.0}}

    day = datetime(2026, 10, 14)
    assert is_online(prof, day.replace(hour=10))
    assert is_online(prof, day.replace(hour=23, minute=59))
    assert not is_online(prof, day.replace(hour=3))     # 凌晨必须不在线
    assert not is_online(prof, day.replace(hour=13))    # 午休

    r = random.Random(42)
    d = plan_reply(prof, day.replace(hour=3), r)
    assert not is_online(prof, day.replace(hour=3))
    assert d.delay_sec > 5 * 3600, d          # 凌晨 3 点 -> 至少等到早上 9 点
    assert "不在线" in d.reason

    d2 = plan_reply(prof, day.replace(hour=10), r)
    assert 20 <= d2.delay_sec <= 600, d2
    assert d2.will_reply

    # reply_rate 的统计意义：0.7 就该有约三成不回
    prof["behavior"]["reply_rate"] = 0.7
    r = random.Random(7)
    hits = sum(plan_reply(prof, day.replace(hour=10), r).will_reply for _ in range(2000))
    assert 1250 < hits < 1550, hits           # 2000 * 0.7 = 1400

    prof["behavior"]["reply_rate"] = 0.0
    r = random.Random(1)
    assert not any(plan_reply(prof, day.replace(hour=10), r).will_reply for _ in range(50))

    assert not plan_proactive(prof, day.replace(hour=10), None, random.Random(1))
    prof["behavior"]["proactive_rate"] = 1.0
    assert plan_proactive(prof, day.replace(hour=10), None, random.Random(1))
    # 一小时内不重复发起
    assert not plan_proactive(prof, day.replace(hour=10), day.replace(hour=9, minute=30),
                              random.Random(1))
    # 凌晨不主动
    assert not plan_proactive(prof, day.replace(hour=3), None, random.Random(1))

    print("scheduler self-check ok")
    prof["behavior"]["reply_rate"] = 0.85
    for h in (3, 10, 13, 23):
        t = day.replace(hour=h)
        dd = plan_reply(prof, t, random.Random(3))
        at = dd.reply_at(t)
        when = f"{at:%d日%H:%M}" if at and (at - t) > timedelta(hours=1) else (
            f"{int(dd.delay_sec)}秒后" if at else "—")
        print(f"  {h:02d}:00 -> {'回' if dd.will_reply else '不回':<3} {when:>10}   {dd.reason}")

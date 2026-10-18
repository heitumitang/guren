/// 时间拟人调度决策 —— server/scheduler.py 的 Dart 复刻。
///
/// 核心判断：真人最大的特征不是说话内容，是「你找 TA 的时候 TA 不一定在」。
import 'dart:math';

const List<List<int>> defaultOnline = [
  [9, 12],
  [14, 18],
  [20, 24],
];
const List<num> defaultDelay = [20, 600];

class Decision {
  final bool willReply;
  final double delaySec;
  final String reason;

  Decision(this.willReply, this.delaySec, this.reason);

  DateTime? replyAt(DateTime now) =>
      willReply ? now.add(Duration(milliseconds: (delaySec * 1000).round())) : null;
}

Map<String, dynamic> _behavior(Map<String, dynamic> profile) {
  final b = Map<String, dynamic>.from(profile['behavior'] as Map? ?? {});
  b['online_hours'] ??= defaultOnline;
  b['reply_delay_sec'] ??= defaultDelay;
  b['reply_rate'] ??= 0.85;
  b['proactive_rate'] ??= 0.1;
  return b;
}

List<List<int>> _hours(Map<String, dynamic> b) {
  final raw = b['online_hours'] as List? ?? defaultOnline;
  return [
    for (final seg in raw)
      if (seg is List && seg.length >= 2) [(seg[0] as num).toInt(), (seg[1] as num).toInt()],
  ];
}

/// 在线时段用 [[start_hour, end_hour], ...]，跨天写成两段，如 [20,24] + [0,2]。
bool isOnline(Map<String, dynamic> profile, DateTime now) =>
    _hours(_behavior(profile)).any((seg) => now.hour >= seg[0] && now.hour < seg[1]);

/// 下一个开始在线的时刻，找不到就 null（说明该时段配置有问题）。
DateTime? nextOnlineStart(Map<String, dynamic> profile, DateTime now) {
  final cands = <DateTime>[];
  for (final seg in _hours(_behavior(profile))) {
    for (final day in [0, 1]) {
      final d = DateTime(
          now.year, now.month, now.day + day, seg[0]);
      if (d.isAfter(now)) cands.add(d);
    }
  }
  if (cands.isEmpty) return null;
  cands.sort();
  return cands.first;
}

String _hm(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// 收到一条消息后，决定回不回、什么时候回。
Decision planReply(Map<String, dynamic> profile, DateTime now, [Random? rng]) {
  final r = rng ?? Random();
  final b = _behavior(profile);
  final will = r.nextDouble() < (b['reply_rate'] as num).toDouble();
  final dl = (b['reply_delay_sec'] as List? ?? defaultDelay);
  final lo = (dl[0] as num).toDouble();
  final hi = dl.length > 1 ? (dl[1] as num).toDouble() : lo;

  if (!isOnline(profile, now)) {
    final nxt = nextOnlineStart(profile, now);
    if (nxt == null) return Decision(false, 0.0, 'online_hours 配置无效，无法排期');
    // ponytail: 睡醒后的延迟单独抖一次，别和在线时的延迟同分布
    final delay = nxt.difference(now).inMilliseconds / 1000.0 +
        (lo + r.nextDouble() * (min(hi, 3600.0) - lo));
    final reason = '不在线（现在 ${_hm(now)}），排到 ${_hm(nxt)} 之后';
    return Decision(will, delay, will ? reason : '$reason，但已读不回');
  }

  final delay = lo + r.nextDouble() * (hi - lo);
  return Decision(will, delay, will ? '在线，正常延迟' : '在线但已读不回');
}

/// TA 会不会主动找你。每小时最多判一次，避免刷屏。
bool planProactive(Map<String, dynamic> profile, DateTime now,
    DateTime? lastProactiveAt, [Random? rng]) {
  final r = rng ?? Random();
  final b = _behavior(profile);
  if (!isOnline(profile, now)) return false;
  if (lastProactiveAt != null &&
      now.difference(lastProactiveAt) < const Duration(hours: 1)) {
    return false;
  }
  return r.nextDouble() < (b['proactive_rate'] as num).toDouble();
}

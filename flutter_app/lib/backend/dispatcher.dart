/// server/dispatcher.py 的 Dart 复刻：生成与投递分离，延迟内容落盘到 pending.json，App 重启后仍可恢复。
import 'dart:async';

import 'store.dart';

class Dispatcher {
  final Store store;

  /// 在飞的投递定时器，按 NPC 分组，reset 时按组取消。
  final Map<String, Set<Timer>> _timers = {};

  Dispatcher(this.store);

  Future<int> pushOutbox(String npcId, Map<String, dynamic> item) async {
    final box = await _loadList(npcId, 'outbox.json');
    box.add(item);
    final trimmed = box.length > 300 ? box.sublist(box.length - 300) : box;
    await store.saveNpc(npcId, 'outbox.json', trimmed);
    return trimmed.length - 1;
  }

  Future<Map<String, dynamic>> readOutbox(String npcId, [int since = 0]) async {
    final box = await _loadList(npcId, 'outbox.json');
    return {'total': box.length, 'items': box.skip(since).toList()};
  }

  Future<List<Map<String, dynamic>>> _loadList(String npcId, String name) async {
    final v = await store.loadNpc(npcId, name, null);
    if (v is! List) return <Map<String, dynamic>>[];
    return v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  }

  Future<void> _dropPending(String npcId, String taskId) async {
    final pending = await _loadList(npcId, 'pending.json');
    pending.removeWhere((t) => t['id'] == taskId);
    await store.saveNpc(npcId, 'pending.json', pending);
  }

  /// 排一条延迟投递（文本已生成，无需 key）。
  Future<String> queueDelivery(String npcId, String text, bool blocked,
      String? reason, DateTime when) async {
    final id = store.newId();
    final task = {
      'id': id,
      'npc_id': npcId,
      'reply_at': when.toIso8601String(),
      'text': text,
      'blocked': blocked,
      'reason': reason,
    };
    final pending = await _loadList(npcId, 'pending.json');
    pending.add(task);
    await store.saveNpc(npcId, 'pending.json', pending);
    _spawn(task);
    return id;
  }

  void _spawn(Map<String, dynamic> task) {
    final npcId = task['npc_id']?.toString() ?? '';
    final when = DateTime.tryParse(task['reply_at']?.toString() ?? '') ?? DateTime.now();
    var delay = when.difference(DateTime.now());
    if (delay.isNegative) delay = Duration.zero;
    final t = Timer(delay, () => _deliver(task));
    _timers.putIfAbsent(npcId, () => <Timer>{}).add(t);
  }

  Future<void> _deliver(Map<String, dynamic> task) async {
    final npcId = task['npc_id']?.toString() ?? '';
    final blocked = task['blocked'] == true;
    final now = DateTime.now();
    await pushOutbox(npcId, {
      'id': task['id'],
      'type': 'reply',
      'at': _iso(now),
      'text': task['text'] ?? '',
      'blocked': blocked,
      'reason': task['reason'],
    });
    if (!blocked) {
      // 回复真正送达时才写 assistant（生成时只写了 user，避免「没回先显示」）
      await store.appendHistory(npcId, [
        {'role': 'assistant', 'content': task['text'] ?? '', 'at': _iso(now)},
      ]);
    }
    await _dropPending(npcId, task['id']?.toString() ?? '');
  }

  /// App 重启后把没投递完的任务重新排上。返回恢复条数。
  Future<int> restore() async {
    var n = 0;
    for (final id in await store.allNpcIds()) {
      for (final t in await _loadList(id, 'pending.json')) {
        _spawn(t);
        n++;
      }
    }
    return n;
  }

  /// 清空指定 NPC（或全部）的在飞投递、待投递和收件箱。
  Future<void> reset([String? npcId]) async {
    if (npcId == null) {
      for (final t in _timers.values.expand((s) => s)) t.cancel();
      _timers.clear();
    } else {
      for (final t in (_timers[npcId] ?? {})) t.cancel();
      _timers.remove(npcId);
    }
    final ids = npcId != null ? [npcId] : await store.allNpcIds();
    for (final id in ids) {
      await store.saveNpc(id, 'pending.json', <dynamic>[]);
      await store.saveNpc(id, 'outbox.json', <dynamic>[]);
    }
  }
}

String _iso(DateTime t) =>
    '${t.year}-${_two(t.month)}-${_two(t.day)}T${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';

String _two(int v) => v.toString().padLeft(2, '0');

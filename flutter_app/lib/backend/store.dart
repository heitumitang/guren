/// 内嵌后端的数据存储 —— server/main.py 存取层的 Dart 复刻。
///
/// 目录布局与 Python 版完全一致，同一份数据两种后端都能读：
///   <root>/index.json
///   <root>/user.json
///   <root>/characters/<id>/persona.json | memory.json | history.json
///   <root>/characters/<id>/outbox.json | pending.json | last_read.json | last_proactive.json
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'schema.dart';

/// 端点抛出的 HTTP 错误，由 server.dart 统一转成状态码 + detail。
class ApiError implements Exception {
  final int status;
  final String message;
  ApiError(this.status, this.message);

  @override
  String toString() => message;
}

final RegExp _idRe = RegExp(r'^[A-Za-z0-9_-]{1,32}$');

class Store {
  final String root;
  Store(this.root);

  Directory get dir => Directory(root);
  Directory get charDir => Directory('$root${Platform.pathSeparator}characters');
  String get indexFile => '$root${Platform.pathSeparator}index.json';
  String get userFile => '$root${Platform.pathSeparator}user.json';

  Future<void> init() async {
    if (!await dir.exists()) await dir.create(recursive: true);
    if (!await charDir.exists()) await charDir.create(recursive: true);
  }

  // ---------- 通用存取 ----------

  Future<dynamic> loadPath(String path, dynamic def) async {
    final f = File(path);
    if (!await f.exists()) return def;
    try {
      return jsonDecode(await f.readAsString());
    } catch (_) {
      return def;
    }
  }

  Future<void> savePath(String path, dynamic data) async {
    final f = File(path);
    if (!await f.parent.exists()) await f.parent.create(recursive: true);
    await f.writeAsString(const JsonEncoder.withIndent(' ').convert(data));
  }

  String npcDir(String id) {
    if (!_idRe.hasMatch(id)) throw ApiError(400, '非法 NPC id：$id');
    return '$root${Platform.pathSeparator}characters${Platform.pathSeparator}$id';
  }

  Future<dynamic> loadNpc(String id, String name, dynamic def) =>
      loadPath('${npcDir(id)}${Platform.pathSeparator}$name', def);

  Future<void> saveNpc(String id, String name, dynamic data) =>
      savePath('${npcDir(id)}${Platform.pathSeparator}$name', data);

  Future<Map<String, dynamic>> needPersona(String id) async {
    final p = await loadNpc(id, 'persona.json', null);
    if (p is! Map) throw ApiError(404, '找不到 NPC $id');
    return Map<String, dynamic>.from(p);
  }

  Future<Map<String, dynamic>> loadMemory(String id) async {
    final raw = await loadNpc(id, 'memory.json', null);
    final base = emptyMemory();
    if (raw == null) return base;
    if (raw is List) {
      return {...base, 'shared': raw};
    }
    if (raw is Map) return {...base, ...Map<String, dynamic>.from(raw)};
    return base;
  }

  Future<List<dynamic>> loadHistory(String id) async {
    final h = await loadNpc(id, 'history.json', null);
    return h is List ? h : <dynamic>[];
  }

  /// 追加聊天记录。每 NPC 独立，退出/重进不丢。只留最近 500 条。
  Future<void> appendHistory(String id, List<Map<String, dynamic>> entries) async {
    final h = await loadHistory(id);
    h.addAll(entries);
    await saveNpc(id, 'history.json', h.length > 500 ? h.sublist(h.length - 500) : h);
  }

  /// 未读 = 比「上次已读」更晚的 assistant 消息条数。
  /// at 与 last_read 同为本地秒级字符串，直接字典序比较即时间序。
  Future<int> unreadCount(String id) async {
    final last = await loadNpc(id, 'last_read.json', null);
    final lastStr = last?.toString();
    var n = 0;
    for (final m in await loadHistory(id)) {
      if (m is! Map) continue;
      if (m['role'] != 'assistant') continue;
      final at = m['at']?.toString();
      if (at == null || at.isEmpty) continue;
      if (lastStr == null || lastStr.isEmpty || at.compareTo(lastStr) > 0) n++;
    }
    return n;
  }

  // ---------- 索引 ----------

  Future<List<dynamic>> readIndex() async {
    final v = await loadPath(indexFile, null);
    return v is List ? v : <dynamic>[];
  }

  Future<void> writeIndex(List<dynamic> items) => savePath(indexFile, items);

  Map<String, dynamic> indexEntry(String id, Map<String, dynamic> persona) {
    final b = persona['basics'] as Map? ?? {};
    String s(dynamic v) => v?.toString() ?? '';
    return {
      'id': id,
      'name': s((persona['meta'] as Map? ?? {})['target_name']).isEmpty
          ? '未命名'
          : s((persona['meta'] as Map? ?? {})['target_name']),
      'emoji': s(persona['emoji']).isEmpty ? '🙂' : s(persona['emoji']),
      'avatar': s(persona['avatar']),
      'relation': s((persona['relationship'] as Map? ?? {})['bond']),
      'basics': {
        for (final k in ['age', 'occupation', 'mbti']) k: s(b[k]),
      },
      'created_at': s((persona['meta'] as Map? ?? {})['created_at']),
      'updated_at': nowIso(),
    };
  }

  Future<void> upsertIndex(String id, Map<String, dynamic> persona) async {
    final items = (await readIndex())
        .where((x) => x is! Map || x['id'] != id)
        .toList();
    items.add(indexEntry(id, persona));
    items.sort((a, b) => ((a as Map)['created_at']?.toString() ?? '')
        .compareTo((b as Map)['created_at']?.toString() ?? ''));
    await writeIndex(items);
  }

  Future<void> dropIndex(String id) async {
    await writeIndex(
        (await readIndex()).where((x) => x is! Map || x['id'] != id).toList());
  }

  Future<List<dynamic>> listIndex() => readIndex();

  String newId() {
    final r = Random();
    const chars = '0123456789abcdef';
    return List.generate(8, (_) => chars[r.nextInt(16)]).join();
  }

  // ---------- 用户档案 ----------

  Future<Map<String, dynamic>> loadUser() async {
    final raw = await loadPath(userFile, null);
    final base = emptyUser();
    if (raw is Map) return {...base, ...Map<String, dynamic>.from(raw)};
    return base;
  }

  Future<void> saveUser(Map<String, dynamic> u) => savePath(userFile, u);

  Future<List<String>> allNpcIds() async {
    if (!await charDir.exists()) return <String>[];
    return [
      for (final e in await charDir.list().toList())
        if (e is Directory) e.uri.pathSegments.where((s) => s.isNotEmpty).last,
    ];
  }
}

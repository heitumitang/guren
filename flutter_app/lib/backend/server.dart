/// App 内嵌后端：dart:io HTTP 服务，只监听 127.0.0.1，端点与 server/main.py 严格对齐。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'dispatcher.dart';
import 'distill.dart' as dz;
import 'engine.dart' as eng;
import 'llm.dart' as llm;
import 'presets.dart' as presetsLib;
import 'scheduler.dart' as sch;
import 'schema.dart';
import 'store.dart';

class EmbeddedServer {
  final Store store;
  late final Dispatcher dispatcher;
  HttpServer? _server;

  EmbeddedServer(String dataRoot) : store = Store(dataRoot) {
    dispatcher = Dispatcher(store);
  }

  int get port => _server?.port ?? 0;
  String get baseUrl => 'http://127.0.0.1:$port';
  bool get running => _server != null;

  Future<int> start({int port = 0}) async {
    if (_server != null) return _server!.port;
    await store.init();
    await dispatcher.restore();
    HttpServer s;
    try {
      s = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    } catch (_) {
      // 固定端口被占就用随机端口，别让 App 起不来
      s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    }
    _server = s;
    s.listen(_handle, onError: (_) {});
    return s.port;
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _handle(HttpRequest req) async {
    _cors(req);
    if (req.method == 'OPTIONS') {
      req.response.statusCode = HttpStatus.noContent;
      await req.response.close();
      return;
    }
    final segs = req.uri.path.split('/').where((s) => s.isNotEmpty).toList();
    dynamic body;
    try {
      final raw = await utf8.decoder.bind(req).join();
      body = raw.isEmpty ? null : jsonDecode(raw);
    } catch (_) {
      body = null;
    }
    try {
      final result = await _route(req.method, segs, body, req.uri.queryParameters);
      await _send(req, HttpStatus.ok, result ?? <String, dynamic>{});
    } on ApiError catch (e) {
      await _send(req, e.status, {'detail': e.message});
    } on llm.NoKey catch (e) {
      await _send(req, HttpStatus.badRequest, {'detail': e.message});
    } on llm.LlmError catch (e) {
      await _send(req, HttpStatus.badGateway, {'detail': '模型调用失败：${e.message}'});
    } on ArgumentError catch (e) {
      await _send(req, HttpStatus.badRequest, {'detail': e.message.toString()});
    } catch (e) {
      await _send(req, HttpStatus.internalServerError, {'detail': '内置后端出错：$e'});
    }
  }

  Future<dynamic> _route(String method, List<String> segs, dynamic body,
      Map<String, String> query) async {
    final b = body is Map ? Map<String, dynamic>.from(body) : <String, dynamic>{};

    if (segs.isEmpty || (segs.length == 1 && segs[0] == 'health')) {
      return {'ok': true, 'characters': (await store.listIndex()).length};
    }

    if (segs.length == 1 && segs[0] == 'user') {
      if (method == 'PUT') {
        final u = <String, String>{
          for (final k in userFields) k: (b[k] ?? '').toString().trim(),
        };
        await store.saveUser(u);
        return {'ok': true, 'user': u};
      }
      return await store.loadUser();
    }

    if (segs.length == 2 && segs[0] == 'config') {
      if (segs[1] == 'test' && method == 'POST') {
        try {
          final text = await llm.complete([
            {'role': 'user', 'content': '回复两个字：收到'}
          ], temperature: 0.1, cfg: b);
          final resolved = llm.resolveConfig(b);
          return {
            'ok': true,
            'reply': text,
            'using': {
              'base_url': resolved['base_url'],
              'model': resolved['model'],
              'api_key': llm.maskKey(resolved['api_key'] ?? ''),
            },
          };
        } on llm.NoKey catch (e) {
          throw ApiError(HttpStatus.badRequest, e.message);
        } on llm.LlmError catch (e) {
          return {'ok': false, 'error': e.message};
        }
      }
      if (segs[1] == 'providers') return {'env_fallback': false};
    }

    if (segs.length == 1 && segs[0] == 'presets') {
      return {'presets': presetsLib.listPresets()};
    }

    if (segs.length == 1 && segs[0] == 'characters') {
      if (method == 'POST') return await _create(b);
      final items = await store.listIndex();
      final out = <dynamic>[];
      for (final it in items) {
        if (it is! Map) continue;
        final m = Map<String, dynamic>.from(it);
        m['unread'] = await store.unreadCount(m['id']?.toString() ?? '');
        out.add(m);
      }
      return {'characters': out};
    }

    if (segs.length == 2 && segs[0] == 'characters') {
      final id = segs[1];
      if (method == 'GET') return await store.needPersona(id);
      if (method == 'DELETE') return await _delete(id);
    }

    if (segs.length == 3 && segs[0] == 'characters') {
      final id = segs[1];
      switch (segs[2]) {
        case 'report':
          await store.needPersona(id);
          final f = File('${store.npcDir(id)}${Platform.pathSeparator}report.md');
          return {'report': await f.exists() ? await f.readAsString() : ''};
        case 'meta':
          return await _updateMeta(id, b);
        case 'review':
          return await _review(id, b);
        case 'scale':
          return await _scale(id, b);
        case 'chat':
          return await _chat(id, b);
        case 'outbox':
          final since = int.tryParse(query['since'] ?? '0') ?? 0;
          return await dispatcher.readOutbox(id, since);
        case 'history':
          return {'messages': await store.loadHistory(id)};
        case 'read':
          await store.needPersona(id);
          await store.saveNpc(id, 'last_read.json', nowIso());
          return {'ok': true};
        case 'proactive':
          return await _proactive(id, b.isEmpty ? null : b);
      }
    }

    if (segs.length == 4 &&
        segs[0] == 'characters' &&
        segs[2] == 'schedule' &&
        segs[3] == 'preview') {
      return await _schedulePreview(segs[1]);
    }

    if (segs.length == 1 && segs[0] == 'distill' && method == 'POST') {
      return await _distill(b);
    }

    if (segs.length == 1 && segs[0] == 'ocr') {
      // 内置后端不跑 Python，RapidOCR 用不了，给句人话避免 UI 崩。
      throw ApiError(
        HttpStatus.badRequest,
        '内置后端不支持截图 OCR（需要 Python 版后端）。手机端请改用「粘贴聊天记录」导入。',
      );
    }

    throw ApiError(HttpStatus.notFound, '未知接口 /${segs.join('/')}');
  }

  Future<Map<String, dynamic>> _create(Map<String, dynamic> b) async {
    final tags = (b['tags'] as List? ?? const []).map((e) => e.toString()).toList();
    final name = (b['name'] ?? '').toString();
    final basics = b['basics'] is Map
        ? Map<String, dynamic>.from(b['basics'] as Map)
        : <String, dynamic>{};
    Map<String, dynamic> prof;
    if (tags.isNotEmpty) {
      try {
        prof = presetsLib.buildFromTags(tags, name.isEmpty ? '未命名' : name, basics);
      } on ArgumentError catch (e) {
        throw ApiError(HttpStatus.badRequest, e.message.toString());
      }
    } else {
      prof = newProfile(targetName: name.isEmpty ? '未命名' : name, sourcePlatform: 'manual');
      (prof['basics'] as Map).addAll(basics);
    }
    if ((b['emoji'] ?? '').toString().isNotEmpty) prof['emoji'] = b['emoji'].toString();
    if ((b['avatar'] ?? '').toString().isNotEmpty) prof['avatar'] = b['avatar'].toString();
    if ((b['relation'] ?? '').toString().isNotEmpty) {
      (prof['relationship'] as Map)['bond'] = b['relation'].toString();
    }
    final id = store.newId();
    await store.saveNpc(id, 'persona.json', prof);
    await store.saveNpc(id, 'memory.json', emptyMemory());
    await store.upsertIndex(id, prof);
    return {'id': id, 'persona': prof};
  }

  Future<Map<String, dynamic>> _delete(String id) async {
    await store.needPersona(id);
    await dispatcher.reset(id);
    await store.saveNpc(id, 'persona.json', newProfile(targetName: '（已删除）'));
    await store.saveNpc(id, 'memory.json', emptyMemory());
    await store.saveNpc(id, 'history.json', <dynamic>[]);
    final lp = File('${store.npcDir(id)}${Platform.pathSeparator}last_proactive.json');
    if (await lp.exists()) {
      try {
        await lp.delete();
      } catch (_) {
        await store.saveNpc(id, 'last_proactive.json', '');
      }
    }
    await store.dropIndex(id);
    return {'ok': true};
  }

  /// 关系双向同步：A 的 relations 变化后，同步到被指向 NPC 的反向关系。
  Future<void> _syncRelations(String id, List<dynamic> oldRels, List<dynamic> newRels) async {
    final p = await store.needPersona(id);
    final myName = ((p['meta'] as Map?)?['target_name']?.toString() ?? '').isNotEmpty
        ? (p['meta'] as Map)['target_name'].toString()
        : id;
    final old = <String, Map<String, dynamic>>{
      for (final r in oldRels)
        if (r is Map && r['npc_id'] != null) r['npc_id'].toString(): Map<String, dynamic>.from(r),
    };
    final nu = <String, Map<String, dynamic>>{
      for (final r in newRels)
        if (r is Map && r['npc_id'] != null) r['npc_id'].toString(): Map<String, dynamic>.from(r),
    };
    for (final otherId in {...old.keys, ...nu.keys}) {
      if (otherId == id) continue;
      final op = await store.loadNpc(otherId, 'persona.json', null);
      if (op is! Map) continue;
      final opMap = Map<String, dynamic>.from(op);
      final opRels = (opMap['relations'] as List? ?? const [])
          .where((r) => r is! Map || r['npc_id'] != id)
          .toList();
      final nr = nu[otherId];
      if (nr != null) {
        opRels.add({
          'npc_id': id,
          'name': myName,
          'relation': nr['relation'] ?? '',
          'share_memory': nr['share_memory'] == true,
          'context': nr['context'] ?? '',
        });
      }
      opMap['relations'] = opRels;
      await store.saveNpc(otherId, 'persona.json', opMap);
      await store.upsertIndex(otherId, opMap);
    }
  }

  Future<Map<String, dynamic>> _updateMeta(String id, Map<String, dynamic> b) async {
    final p = await store.needPersona(id);
    final oldRels = List<dynamic>.from(p['relations'] as List? ?? const []);
    if ((b['name'] ?? '').toString().isNotEmpty) {
      (p['meta'] as Map)['target_name'] = b['name'].toString();
    }
    if ((b['emoji'] ?? '').toString().isNotEmpty) p['emoji'] = b['emoji'].toString();
    if (b.containsKey('avatar')) p['avatar'] = (b['avatar'] ?? '').toString();
    if (b.containsKey('relation')) {
      (p['relationship'] as Map)['bond'] = (b['relation'] ?? '').toString();
    }
    if (b.containsKey('rel_context')) {
      (p['relationship'] as Map)['context'] = (b['rel_context'] ?? '').toString();
    }
    if (b.containsKey('call_me')) {
      (p['relationship'] as Map)['call_me'] = (b['call_me'] ?? '').toString();
    }
    if (b['basics'] is Map) {
      final pb = p['basics'] as Map;
      for (final e in (b['basics'] as Map).entries) {
        if (pb.containsKey(e.key)) pb[e.key] = e.value;
      }
    }
    if (b['relations'] != null) {
      p['relations'] = b['relations'];
    }
    await store.saveNpc(id, 'persona.json', p);
    await store.upsertIndex(id, p);
    if (b['relations'] != null) {
      await _syncRelations(id, oldRels, List<dynamic>.from(p['relations'] as List? ?? const []));
    }
    return {'ok': true, 'persona': p};
  }

  Future<Map<String, dynamic>> _review(String id, Map<String, dynamic> b) async {
    final p = await store.needPersona(id);
    final traits = b['traits'] as Map? ?? {};
    final flaws = b['flaws'] as Map? ?? {};
    for (final t in p['traits'] as List? ?? const []) {
      if (t is Map && traits.containsKey(t['name'])) t['review'] = traits[t['name']];
    }
    for (final f in p['flaws'] as List? ?? const []) {
      if (f is Map && flaws.containsKey(f['type'])) f['review'] = flaws[f['type']];
    }
    final issues = validateProfile(p);
    p['review_status'] = issues.isEmpty ? 'approved' : 'draft';
    await store.saveNpc(id, 'persona.json', p);
    return {'ok': true, 'issues': issues};
  }

  Future<Map<String, dynamic>> _scale(String id, Map<String, dynamic> b) async {
    final p = await store.needPersona(id);
    final v = clamp(b['flaw_intensity_scale'] ?? 0.7);
    p['flaw_intensity_scale'] = v;
    if (b['reply_rate'] != null) {
      (p['behavior'] as Map)['reply_rate'] = clamp(b['reply_rate']);
    }
    await store.saveNpc(id, 'persona.json', p);
    return {'ok': true, 'flaw_intensity_scale': v};
  }

  Future<Map<String, dynamic>> _chat(String id, Map<String, dynamic> b) async {
    final p = await store.needPersona(id);
    final mem = await store.loadMemory(id);
    final cfg = b['llm'] is Map ? Map<String, dynamic>.from(b['llm'] as Map) : null;
    final now = DateTime.now();
    final immediate = b['immediate'] == true;
    final message = (b['message'] ?? '').toString();

    final d = immediate
        ? sch.Decision(true, 0.0, '立即模式')
        : sch.planReply(p, now);

    // 引用回复：把被引用的原话拼进当前消息（微信式引用样式）
    var userMessage = message;
    final quote = b['quote'];
    if (quote is Map && (quote['text'] ?? '').toString().isNotEmpty) {
      final qRole = quote['role'] == 'user'
          ? '我'
          : ((p['meta'] as Map?)?['target_name']?.toString() ?? 'TA');
      userMessage = '「引用 $qRole：${quote['text']}」\n$userMessage';
    }

    // 已读不回也要落盘用户消息（标已读），切走再回来不丢
    if (!d.willReply) {
      await store.appendHistory(id, [
        {'role': 'user', 'content': message, 'at': nowIso(now), 'read': true},
      ]);
      return {'will_reply': false, 'reason': d.reason, 'reply_at': null};
    }

    // 先把用户消息落盘（延迟/立即/拦截都覆盖），否则切走再回来或 LLM 还在跑时会丢
    await store.appendHistory(id, [
      {'role': 'user', 'content': message, 'at': nowIso(now)},
    ]);

    // 上下文历史：客户端没传时兜底从存储读（最后一条是刚落盘的当前消息，要排除）
    var history = (b['history'] as List?) ?? const [];
    if (history.isEmpty) {
      final all = await store.loadHistory(id);
      if (all.length > 1) {
        final end = all.length - 1;
        history = all.sublist(end > 12 ? end - 12 : 0, end);
      }
    }

    Map<String, dynamic> out;
    try {
      out = await eng.chat(p, userMessage,
          history: history,
          memoryLines: mem,
          cfg: cfg,
          userProfile: await store.loadUser());
    } on llm.NoKey catch (e) {
      throw ApiError(HttpStatus.badRequest, '${e.message}。先测一下 key');
    } on llm.LlmError catch (e) {
      throw ApiError(HttpStatus.badGateway, '模型调用失败：${e.message}');
    }

    if (out['blocked'] == true) {
      return {
        'will_reply': true,
        'delivered': false,
        'blocked': true,
        'reason': out['reason'],
        'raw': out['raw'],
      };
    }

    final nu = await eng.extractMemories(p, message, out['reply'].toString(), cfg: cfg);
    if (nu.values.any((v) => v.isNotEmpty)) {
      await store.saveNpc(id, 'memory.json', eng.mergeMemory(mem, nu));
    }

    // 立即模式补写 assistant；延迟模式由 dispatcher 投递时写，避免「提前看到」
    if (immediate) {
      await store.appendHistory(id, [
        {'role': 'assistant', 'content': out['reply'], 'at': nowIso()},
      ]);
      return {
        'will_reply': true,
        'delivered': true,
        'text': out['reply'],
        'blocked': false,
      };
    }

    final at = d.replyAt(now)!;
    final tid = await dispatcher.queueDelivery(
        id, out['reply'].toString(), false, null, at);
    return {
      'will_reply': true,
      'delivered': false,
      'task_id': tid,
      'reply_at': nowIso(at),
      'delay_sec': d.delaySec.round(),
      'reason': d.reason,
    };
  }

  Future<Map<String, dynamic>> _proactive(String id, Map<String, dynamic>? body) async {
    final p = await store.needPersona(id);
    final mem = await store.loadMemory(id);
    final lastRaw = await store.loadNpc(id, 'last_proactive.json', null);
    final now = DateTime.now();
    final last = (lastRaw is String && lastRaw.isNotEmpty) ? DateTime.tryParse(lastRaw) : null;

    if (!sch.planProactive(p, now, last)) return {'initiated': false};

    const trigger =
        '（现在没有任何人跟你说话。根据你记得的事，主动说一句你现在想说的话。'
        '一句话，像微信消息一样短。不要解释为什么突然找 TA。）';
    Map<String, dynamic> out;
    try {
      out = await eng.chat(p, trigger,
          history: const [], memoryLines: mem, cfg: body, userProfile: await store.loadUser());
    } on llm.NoKey catch (e) {
      throw ApiError(HttpStatus.badRequest, e.message);
    } on llm.LlmError catch (e) {
      throw ApiError(HttpStatus.badGateway, '模型调用失败：${e.message}');
    }

    if (out['blocked'] == true) {
      return {'initiated': false, 'blocked': true, 'reason': out['reason']};
    }

    final at = nowIso();
    await store.saveNpc(id, 'last_proactive.json', at);
    await dispatcher.pushOutbox(id, {
      'id': 'pro',
      'type': 'proactive',
      'at': at,
      'text': out['reply'],
      'blocked': false,
      'reason': null,
    });
    await store.appendHistory(id, [
      {'role': 'assistant', 'content': out['reply'], 'at': at},
    ]);
    return {'initiated': true, 'text': out['reply']};
  }

  Future<Map<String, dynamic>> _schedulePreview(String id) async {
    final p = await store.needPersona(id);
    final now = DateTime.now();
    final d = sch.planReply(p, now);
    final at = d.replyAt(now);
    return {
      'now': nowIso(now),
      'online': sch.isOnline(p, now),
      'will_reply': d.willReply,
      'delay_sec': d.delaySec.round(),
      'reply_at': at == null ? null : nowIso(at),
      'reason': d.reason,
    };
  }

  Future<Map<String, dynamic>> _distill(Map<String, dynamic> b) async {
    final msgsRaw = b['messages'] as List? ?? const [];
    if (msgsRaw.isEmpty) throw ApiError(HttpStatus.badRequest, 'messages 不能为空');
    final msgs = msgsRaw.toList();
    final cfg = b['llm'] is Map ? Map<String, dynamic>.from(b['llm'] as Map) : null;
    final targetName = (b['target_name'] ?? '').toString();

    Map<String, dynamic> raw;
    try {
      raw = await dz.callDistill(dz.buildPrompt(msgs, targetName: targetName), cfg);
    } on llm.NoKey catch (e) {
      throw ApiError(HttpStatus.badRequest, '${e.message}。先测一下 key');
    } on llm.LlmError catch (e) {
      throw ApiError(HttpStatus.badGateway, '模型调用失败：${e.message}');
    }

    final issues = dz.validateDistill(raw, msgs);
    final prof = fromDistill(raw, {
      'target_name': targetName,
      'source_platform': 'web',
      'source_message_count': msgs.length,
      'distilled_by': llm.resolveConfig(cfg)['model'],
    });
    if ((b['emoji'] ?? '').toString().isNotEmpty) prof['emoji'] = b['emoji'].toString();
    if ((b['avatar'] ?? '').toString().isNotEmpty) prof['avatar'] = b['avatar'].toString();
    if (b['basics'] is Map) {
      final pb = prof['basics'] as Map;
      for (final e in (b['basics'] as Map).entries) {
        if (pb.containsKey(e.key)) pb[e.key] = e.value;
      }
    }
    if ((b['relation'] ?? '').toString().isNotEmpty) {
      (prof['relationship'] as Map)['bond'] = b['relation'].toString();
    }

    var npcId = (b['npc_id'] ?? '').toString();
    if (npcId.isNotEmpty) {
      final old = await store.loadNpc(npcId, 'persona.json', null);
      if (old is Map) {
        prof['basics'] = old['basics'] ?? prof['basics'];
        prof['relations'] = old['relations'] ?? <dynamic>[];
        prof['emoji'] = old['emoji'] ?? prof['emoji'] ?? '🙂';
        prof['avatar'] = old['avatar'] ?? '';
        final or = old['relationship'] as Map? ?? {};
        (prof['relationship'] as Map)['call_me'] = or['call_me'] ?? '';
        (prof['relationship'] as Map)['context'] = or['context'] ?? '';
      }
      await store.saveNpc(npcId, 'persona.json', prof);
      await store.saveNpc(
          npcId, 'report.md', dz.renderReport(raw, msgs, issues));
    } else {
      npcId = store.newId();
      await store.saveNpc(npcId, 'persona.json', prof);
      await store.saveNpc(
          npcId, 'report.md', dz.renderReport(raw, msgs, issues));
    }

    // 换人就清空旧人的记忆/聊天记录/收件箱/主动记录
    await store.saveNpc(npcId, 'memory.json', emptyMemory());
    await store.saveNpc(npcId, 'history.json', <dynamic>[]);
    final lp = File('${store.npcDir(npcId)}${Platform.pathSeparator}last_proactive.json');
    if (await lp.exists()) {
      try {
        await lp.delete();
      } catch (_) {}
    }
    await dispatcher.reset(npcId);
    await store.upsertIndex(npcId, prof);
    return {
      'ok': true,
      'id': npcId,
      'hallucination_issues': issues,
      'traits': (prof['traits'] as List).length,
      'flaws': (prof['flaws'] as List).length,
    };
  }

  void _cors(HttpRequest req) {
    final h = req.response.headers;
    h.add('Access-Control-Allow-Origin', '*');
    h.add('Access-Control-Allow-Methods', 'GET,POST,PUT,DELETE,OPTIONS');
    h.add('Access-Control-Allow-Headers', '*');
  }

  Future<void> _send(HttpRequest req, int status, Object payload) async {
    req.response.statusCode = status;
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(payload));
    await req.response.close();
  }
}

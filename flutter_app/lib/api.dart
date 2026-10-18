/// 后端 FastAPI 服务的 Dart 客户端，端点与 server/main.py 对齐。
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'models.dart';

class ApiException implements Exception {
  final int? status;
  final String message;
  ApiException(this.status, this.message);
  @override
  String toString() => 'ApiException(${status ?? '?'})：$message';
}

class ApiClient {
  String baseUrl;

  ApiClient(this.baseUrl);

  Uri _u(String path, [Map<String, String>? q]) {
    final clean = baseUrl.replaceAll(RegExp(r'/*$'), '');
    return Uri.parse('$clean$path').replace(queryParameters: q);
  }

  Future<dynamic> _get(String path, [Map<String, String>? q]) async {
    final r = await http.get(_u(path, q));
    return _decode(r);
  }

  Future<dynamic> _post(String path, Map<String, dynamic> body,
      [Map<String, String>? q]) async {
    final r = await http.post(_u(path, q),
        headers: {'Content-Type': 'application/json'}, body: jsonEncode(body));
    return _decode(r);
  }

  Future<dynamic> _put(String path, Map<String, dynamic> body) async {
    final r = await http.put(_u(path),
        headers: {'Content-Type': 'application/json'}, body: jsonEncode(body));
    return _decode(r);
  }

  Future<dynamic> _delete(String path) async {
    final r = await http.delete(_u(path));
    return _decode(r);
  }

  dynamic _decode(http.Response r) {
    dynamic body;
    try {
      body = jsonDecode(utf8.decode(r.bodyBytes));
    } catch (_) {
      body = null;
    }
    if (r.statusCode >= 400) {
      final msg = (body is Map)
          ? ((body['detail'] ?? body['error'] ?? 'HTTP ${r.statusCode}').toString())
          : 'HTTP ${r.statusCode}';
      throw ApiException(r.statusCode, msg);
    }
    return body;
  }

  Future<Map<String, dynamic>> getHealth() async =>
      (await _get('/health')) as Map<String, dynamic>;

  Future<ConfigTestResult> testConfig(LLMConfig llm) async =>
      ConfigTestResult.fromJson(
          (await _post('/config/test', llm.toJson())) as Map<String, dynamic>);

  Future<PresetsResult> getPresets() async =>
      PresetsResult.fromJson((await _get('/presets')) as Map<String, dynamic>);

  Future<UserProfile> getUser() async =>
      UserProfile.fromJson((await _get('/user')) as Map<String, dynamic>);

  Future<UserProfile> putUser(UserProfile u) async {
    final j = (await _put('/user', u.toJson())) as Map<String, dynamic>;
    return UserProfile.fromJson(j['user'] as Map<String, dynamic>);
  }

  Future<List<CharacterIndex>> listCharacters() async {
    final j = (await _get('/characters')) as Map<String, dynamic>;
    return (j['characters'] as List)
        .map((e) => CharacterIndex.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<Persona> getCharacter(String id) async =>
      Persona((await _get('/characters/$id')) as Map<String, dynamic>);

  /// 蒸馏报告（report.md）；手动创建的人物没有报告，返回空串。
  Future<String> getReport(String id) async {
    final j = (await _get('/characters/$id/report')) as Map<String, dynamic>;
    return (j['report'] ?? '').toString();
  }

  Future<CreateResult> createCharacter({
    required String name,
    List<String> tags = const [],
    String emoji = '',
    String avatar = '',
    Map<String, dynamic> basics = const {},
    String relation = '',
  }) async {
    final j = (await _post('/characters', {
      'name': name,
      'tags': tags,
      'emoji': emoji,
      'avatar': avatar,
      'basics': basics,
      'relation': relation,
    })) as Map<String, dynamic>;
    return CreateResult.fromJson(j);
  }

  Future<void> deleteCharacter(String id) async => _delete('/characters/$id');

  Future<Persona> updateMeta(String id, Map<String, dynamic> meta) async {
    final j = (await _put('/characters/$id/meta', meta)) as Map<String, dynamic>;
    return Persona(j['persona'] as Map<String, dynamic>);
  }

  Future<void> review(String id, Map<String, String> traits,
      Map<String, String> flaws) async {
    await _post('/characters/$id/review', {'traits': traits, 'flaws': flaws});
  }

  Future<void> scale(String id, double flawIntensity, [double? replyRate]) async {
    final body = <String, dynamic>{'flaw_intensity_scale': flawIntensity};
    if (replyRate != null) body['reply_rate'] = replyRate;
    await _post('/characters/$id/scale', body);
  }

  Future<DistillResult> distill({
    required List<Map<String, dynamic>> messages,
    required String targetName,
    String npcId = '',
    String emoji = '',
    String avatar = '',
    Map<String, dynamic> basics = const {},
    String relation = '',
    LLMConfig? llm,
  }) async {
    final body = <String, dynamic>{
      'messages': messages,
      'target_name': targetName,
      'npc_id': npcId,
      'emoji': emoji,
      'avatar': avatar,
      'basics': basics,
      'relation': relation,
    };
    if (llm != null) body['llm'] = llm.toJson();
    final j = (await _post('/distill', body)) as Map<String, dynamic>;
    return DistillResult.fromJson(j);
  }

  Future<ChatResult> chat(
    String id, {
    required String message,
    List<Map<String, dynamic>> history = const [],
    Quote? quote,
    LLMConfig? llm,
    bool immediate = false,
  }) async {
    final body = <String, dynamic>{
      'message': message,
      'history': history,
      'immediate': immediate,
    };
    if (quote != null) body['quote'] = quote.toJson();
    if (llm != null) body['llm'] = llm.toJson();
    final j = (await _post('/characters/$id/chat', body)) as Map<String, dynamic>;
    return ChatResult.fromJson(j);
  }

  Future<List<ChatMessage>> history(String id) async {
    final j = (await _get('/characters/$id/history')) as Map<String, dynamic>;
    return (j['messages'] as List)
        .map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 收件箱。后端以 {"total","items"} 返回，读取 items 字段。
  Future<List<OutboxItem>> outbox(String id, {int since = 0}) async {
    final j = await _get('/characters/$id/outbox',
        {'since': since.toString()});
    final list = (j is List)
        ? j
        : (j is Map
            ? ((j['items'] is List
                ? j['items'] as List
                : (j['messages'] is List ? j['messages'] as List : <dynamic>[])))
            : <dynamic>[]);
    return list
        .map((e) => OutboxItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 标记已读，清空该 NPC 的未读红点。
  Future<void> markRead(String id) async => _post('/characters/$id/read', {});

  Future<ProactiveResult> proactive(String id, [LLMConfig? llm]) async {
    final body = llm != null ? llm.toJson() : <String, dynamic>{};
    final j = (await _post('/characters/$id/proactive', body))
        as Map<String, dynamic>;
    return ProactiveResult.fromJson(j);
  }

  Future<SchedulePreview> schedulePreview(String id) async =>
      SchedulePreview.fromJson(
          (await _get('/characters/$id/schedule/preview')) as Map<String, dynamic>);

  Future<OcrResult> ocr(List<String> images, {String targetSide = 'left'}) async {
    final j = (await _post('/ocr', {
      'images': images,
      'target_side': targetSide,
    })) as Map<String, dynamic>;
    return OcrResult.fromJson(j);
  }
}

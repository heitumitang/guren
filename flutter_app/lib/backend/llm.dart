/// 内嵌后端 LLM 调用层（validator/llm.py 的 Dart 复刻）：API key 由用户填写、只存本机、随请求带入。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

const String kDefaultBaseUrl = 'https://api.deepseek.com';
const String kDefaultModel = 'deepseek-chat';

/// 没填 key。让调用方决定是报错还是引导用户去设置页。
class NoKey implements Exception {
  final String message;
  NoKey(this.message);

  @override
  String toString() => message;
}

/// 模型调用/网络失败（对应 Python 版抛的 RuntimeError）。
class LlmError implements Exception {
  final String message;
  LlmError(this.message);

  @override
  String toString() => message;
}

/// 客户端传的配置优先，缺了用默认值兜底。
Map<String, String> resolveConfig([Map<String, dynamic>? cfg]) {
  final c = cfg ?? const <String, dynamic>{};
  final key = (c['api_key'] ?? '').toString().trim();
  var base = (c['base_url'] ?? '').toString().trim();
  var model = (c['model'] ?? '').toString().trim();
  if (base.isEmpty) base = kDefaultBaseUrl;
  if (model.isEmpty) model = kDefaultModel;
  // 用户可能只填了 "api.deepseek.com/v1"（没带协议），补上，别让 Uri.parse 炸掉
  if (!base.startsWith('http://') && !base.startsWith('https://')) {
    base = 'https://$base';
  }
  while (base.endsWith('/')) {
    base = base.substring(0, base.length - 1);
  }
  return {'api_key': key, 'base_url': base, 'model': model};
}

String maskKey(String key) =>
    key.length > 8 ? '${key.substring(0, 4)}…${key.substring(key.length - 4)}' : '***';

/// 发一次 chat completion，返回文本内容。
///
/// jsonMode 走结构化输出，部分 provider 不认 response_format，会自动降级重试。
Future<String> complete(
  List<Map<String, dynamic>> messages, {
  double temperature = 0.9,
  Map<String, dynamic>? cfg,
  bool jsonMode = false,
}) async {
  final c = resolveConfig(cfg);
  if (c['api_key']!.isEmpty) {
    throw NoKey('没有 API key。在设置页填你自己的 key');
  }

  Future<String> post(bool useJson) async {
    final body = <String, dynamic>{
      'model': c['model'],
      'messages': messages,
      'temperature': temperature,
    };
    if (useJson) body['response_format'] = {'type': 'json_object'};

    http.Response r;
    try {
      r = await http
          .post(
            Uri.parse('${c['base_url']}/chat/completions'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer ${c['api_key']}',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 180));
    } on TimeoutException {
      throw LlmError('请求 ${c['base_url']} 超时（180 秒）');
    } on SocketException catch (e) {
      throw LlmError('连不上 ${c['base_url']}：${e.message}');
    } catch (e) {
      throw LlmError('连不上 ${c['base_url']}：$e');
    }

    if (r.statusCode >= 400) {
      final detail = utf8.decode(r.bodyBytes, allowMalformed: true);
      if (useJson) return post(false);
      throw LlmError(
          '${r.statusCode} ${detail.length > 200 ? detail.substring(0, 200) : detail}');
    }

    final decoded = jsonDecode(utf8.decode(r.bodyBytes, allowMalformed: true));
    final choices = (decoded is Map) ? decoded['choices'] : null;
    if (choices is List && choices.isNotEmpty) {
      final msg = (choices.first as Map)['message'];
      if (msg is Map) return (msg['content'] ?? '').toString().trim();
    }
    throw LlmError('模型返回格式异常：${utf8.decode(r.bodyBytes, allowMalformed: true)}');
  }

  return post(jsonMode);
}

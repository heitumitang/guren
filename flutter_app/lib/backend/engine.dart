/// 人格引擎 —— server/engine.py 的 Dart 复刻。
///
/// 组装提示词 -> 调 LLM -> 输出红线过滤 -> 记忆。
/// 红线在提示词里写死了，但提示词能被绕过，所以这里再拦一道。
import 'llm.dart';
import 'schema.dart';

const List<String> abuseWords = ['傻逼', '智障', '去死', '滚蛋', '有病吧', '废物', '贱'];

final RegExp emailRe = RegExp(r'[\w.+-]+@[\w-]+\.[\w.]+');
final RegExp selfHarmRe = RegExp(r'(怎么自杀|去死吧|不想活了|自残的方法|哪种死法)');

/// 归一化时剥掉的标点/空白。用 \u0027 表示单引号，免得和 Dart 字符串引号打架。
final RegExp punctRe =
    RegExp('[\\s，。！？、,.!?…~～"\u0027「」“”]+');

/// 返回违规原因，null = 通过。这是安全路径，别简化掉。
String? redlineCheck(String text) {
  for (final w in abuseWords) {
    if (text.contains(w)) return '疑似人身攻击：含「$w」';
  }
  // ponytail: 不用 lookbehind（Dart RegExp 支持但不稳），改成取到匹配后手动看边界
  if (_hasIsolated(RegExp(r'1[3-9]\d{9}'), text)) return '疑似泄露手机号';
  if (_hasIsolated(RegExp(r'\d{17}[\dXx]'), text)) return '疑似泄露身份证';
  if (_hasIsolated(RegExp(r'\d{16,19}'), text)) return '疑似泄露银行卡';
  if (emailRe.hasMatch(text)) return '疑似泄露邮箱';
  if (selfHarmRe.hasMatch(text)) return '疑似自我伤害内容';
  return null;
}

/// 找到匹配且左右都不是数字（等价于 Python 的 (?<!\d)...(?!\d)）。
bool _hasIsolated(RegExp re, String text) {
  for (final m in re.allMatches(text)) {
    final before = m.start > 0 ? text[m.start - 1] : '';
    final after = m.end < text.length ? text[m.end] : '';
    if (_isDigit(before) || _isDigit(after)) continue;
    return true;
  }
  return false;
}

bool _isDigit(String s) => s.isNotEmpty && RegExp(r'\d').hasMatch(s);

/// 检测回复是否原样复述了对话/例句内容。返回被复述的原话，null=没复述。
String? echoCheck(String reply, String userMessage, List<dynamic>? history) {
  String norm(String s) => s.replaceAll(punctRe, '').trim();

  final r = norm(reply);
  if (r.length < 4) return null; // 太短的（"嗯""哦"）不算复述

  final candidates = <String>[];
  if (userMessage.isNotEmpty) candidates.add(userMessage);
  final h = (history ?? const []).reversed.take(4);
  for (final x in h) {
    if (x is Map && x['content'] != null) candidates.add(x['content'].toString());
  }

  for (final text in candidates) {
    final n = norm(text);
    if (n.length >= 6 && r.contains(n) && r.length <= n.length * 1.2) return text;
    if (n.length >= 8 && r.length >= 8) {
      var common = 0;
      for (final c in n.split('').toSet()) {
        if (r.contains(c)) common++;
      }
      final ratio = common / (n.split('').toSet().length);
      if (ratio > 0.9 && (r.length - n.length).abs() <= 3) return text;
    }
  }
  return null;
}

/// 一次对话。返回 {"reply", "blocked", "reason", "raw"}。
Future<Map<String, dynamic>> chat(
  Map<String, dynamic> profile,
  String userMessage, {
  List<dynamic>? history,
  dynamic memoryLines,
  Map<String, dynamic>? cfg,
  Map<String, dynamic>? userProfile,
}) async {
  final system = renderSystemPrompt(profile,
      memoryLines: memoryLines, userProfile: userProfile);
  final msgs = <Map<String, dynamic>>[
    {'role': 'system', 'content': system},
  ];
  for (final h in history ?? const []) {
    if (h is Map && h['role'] != null && h['content'] != null) {
      msgs.add({'role': h['role'], 'content': h['content']});
    }
  }
  msgs.add({'role': 'user', 'content': userMessage});

  var reply = await complete(msgs, temperature: 0.9, cfg: cfg);

  // 偶发复述：第一次命中就带更强指令重生成一次，仍复述才放弃
  final echoed = echoCheck(reply, userMessage, history);
  if (echoed != null) {
    final retryMsgs = [
      ...msgs,
      {'role': 'assistant', 'content': reply},
      {
        'role': 'user',
        'content': '（注意：你刚把「${echoed.substring(0, echoed.length > 20 ? 20 : echoed.length)}'
            '」原样搬出来了。那是原话不是台词。用自己的话重新回，别复述。）',
      },
    ];
    try {
      final retry = await complete(retryMsgs, temperature: 0.9, cfg: cfg);
      if (echoCheck(retry, userMessage, history) == null) reply = retry;
    } catch (_) {
      // 重试失败就用第一次结果，不炸主流程
    }
  }

  final reason = redlineCheck(reply);
  if (reason != null) {
    // 不重试、不改写——直接拦下暴露给人看，silent fix 会掩盖人格跑偏
    return {'reply': '', 'blocked': true, 'reason': reason, 'raw': reply};
  }
  return {'reply': reply, 'blocked': false, 'reason': null, 'raw': reply};
}

/// 从一轮对话里抽三层记忆。返回 {"self": [...], "user": [...], "shared": [...]}。
Future<Map<String, List<dynamic>>> extractMemories(
  Map<String, dynamic> profile,
  String userMessage,
  String reply, {
  Map<String, dynamic>? cfg,
}) async {
  final who = (profile['meta'] as Map? ?? {})['target_name']?.toString() ?? '对方';
  final prompt = '从下面这段对话里，抽出值得长期记住的事实。严格按三行输出，没有就留空：\n'
      'self: 关于你（$who）自己的近况、习惯、观点，用「我」开头写，不要出现名字\n'
      'user: 关于跟 TA 聊天那个人的近况、偏好\n'
      'shared: 两人之间的约定、共同经历\n\n'
      '要求：每行不超过 15 字，只陈述事实不评价，没有值得记的就空着。\n'
      '注意：不要把『你们俩是什么关系』『你是谁的什么人』这类定义存成记忆——'
      '关系以档案为准，只存具体的新事件、新近况、新约定。\n\n'
      '用户：$userMessage\n$who：$reply';

  final mem = emptyMemory();
  String out;
  try {
    out = await complete([
      {'role': 'user', 'content': prompt}
    ], temperature: 0.2, cfg: cfg);
  } catch (_) {
    return mem; // ponytail: 记忆抽不到不影响对话本身，别让它炸掉主流程
  }

  for (final line in out.split('\n')) {
    for (final k in mem.keys.toList()) {
      if (!line.trim().startsWith(k)) continue;
      final idx = line.indexOf(':');
      if (idx < 0) continue; // 模型输出「self」没带冒号，跳过
      var v = line.substring(idx + 1).trim();
      v = v.replaceAll(RegExp(r'^[ -・]+'), '').replaceAll(RegExp(r'[ -・]+$'), '');
      if (k == 'self') {
        if (v.startsWith(who)) v = v.substring(who.length).replaceAll(RegExp(r'^[ ，,、]+'), '');
        if (v.isEmpty) continue; // 剥完是空的就丢，别存出一条光秃秃的「我」
        if (!v.startsWith('我')) v = '我$v';
      }
      if (v.isNotEmpty) mem[k]!.add(v.length > 30 ? v.substring(0, 30) : v);
    }
  }
  return mem;
}

/// 按层合并去重，每层只留最近 cap 条。
Map<String, List<dynamic>> mergeMemory(Map<String, dynamic>? old,
    Map<String, List<dynamic>> nu, {int cap = 50}) {
  final out = emptyMemory();
  for (final k in out.keys.toList()) {
    final seen = ((old?[k] as List?) ?? const []).map((e) => e.toString()).toList();
    for (final item in [...seen, ...(nu[k] ?? const [])]) {
      final s = item.toString();
      if (s.isNotEmpty && !out[k]!.contains(s)) out[k]!.add(s);
    }
    if (out[k]!.length > cap) out[k] = out[k]!.sublist(out[k]!.length - cap);
  }
  return out;
}

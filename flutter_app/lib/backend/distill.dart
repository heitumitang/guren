/// 对话流 -> 人格档案草稿（带证据链）+ 防幻觉校验 + 校准报告（validator/distill.py 的 Dart 复刻）。
import 'dart:convert';

import 'llm.dart';

const String distillSystemPrompt = '''你是一个人格分析器，任务是从聊天记录里还原一个人的真实性格画像。

铁律：
1. 每一条结论都必须附 evidence —— 引用对方说过的原话序号。没有证据就不要写，宁可少写。
2. traits 和 flaws 的 evidence 只能引用「对方」说的话，绝不能引用「用户」的话。
   唯一例外是 relationship：关系看的是双方互动（谁更主动要对比两边），可以引用任一方。
3. 不要美化。不要因为他偶尔说了句体贴的话就写"温柔体贴"。请判断这是常态还是偶发。
4. 必须找出缺点。一个没有缺点的人不是真人。找：敷衍、误解、回避、偏见、知识盲区、情绪化、迟到失联。
5. 区分"他是什么样的人"和"他和这个用户是什么关系"。同一个人在不同人面前表现不同。
6. 如果样本量不足以支撑某类判断，写进 warnings，而不是编一条出来。
7. traits/flaws 的 description 必须是行为规则：「在什么情况下，他会怎么做、怎么说」。
   禁止只写形容词。「嘴硬」不合格，「被指出问题先否认，用'不算''意外'强行辩解」才合格。
8. style_samples 的 replies 只能是聊天记录里他真正说过的原话（可以截断），一个字都不许改写或新编。

只输出 JSON，不要任何解释文字、不要 markdown 代码块。''';

const String distillOutputSpec = '''输出严格遵循这个 JSON 结构：
{
  "target_name": "对方称呼，从对话推断",
  "traits": [
    {"name": "特质名，4-8字", "description": "行为规则：在什么情况下会怎么做怎么说，禁止只写形容词",
     "weight": 0.0-1.0, "confidence": 0.0-1.0, "evidence": [消息序号]}
  ],
  "style_samples": [
    {"situation": "情境，如：被调侃时 / 对方分享好消息时 / 对方抱怨时 / 被追问时 / 不想聊时 / 日常打招呼",
     "replies": ["他在这个情境下说过的原话（照抄，可截断）", "另一条原话"],
     "evidence": [消息序号]}
  ],
  "speech_style": {
    "sentence_length": "short|medium|long",
    "catchphrases": ["口头禅或高频句式"],
    "punctuation": "标点习惯，如：不用句号、爱用省略号",
    "emoji_usage": "表情/emoji使用习惯",
    "response_speed": "从对话间隔看出的回复节奏",
    "tone": "整体语气"
  },
  "knowledge_bounds": {
    "confident": ["他明显懂、聊起来自信的领域"],
    "shaky": ["他一知半解、会说错的领域"],
    "clueless": ["他明显不懂、会回避或搞错的领域"]
  },
  "flaws": [
    {"type": "缺点类型", "description": "具体表现",
     "intensity": 0.0-1.0, "evidence": [消息序号]}
  ],
  "relationship": {
    "bond": "他和用户的关系性质",
    "asymmetry": "谁更主动、谁更在意，从回复长度和发起频率判断",
    "evidence": [消息序号]
  },
  "flagged_samples": [
    {"index": 消息序号, "reason": "为什么这条适合当 few-shot 样本"}
  ],
  "warnings": ["样本不足或存疑的地方"]
}''';

/// 给缺「i」的消息按位置补序号。
List<Map<String, dynamic>> ensureIndex(List<dynamic> messages) => [
      for (var i = 0; i < messages.length; i++)
        if (messages[i] is Map)
          {...Map<String, dynamic>.from(messages[i] as Map), 'i': (messages[i] as Map)['i'] ?? i},
    ];

String buildPrompt(List<dynamic> messages, {String? targetName, int maxMsgs = 400}) {
  final sample = messages.length > maxMsgs
      ? messages.sublist(messages.length - maxMsgs)
      : messages;
  final offset = messages.length - sample.length;
  final lines = <String>[];
  for (var idx = 0; idx < sample.length; idx++) {
    final m = sample[idx] as Map? ?? {};
    final i = m['i'] ?? offset + idx;
    final who = m['speaker'] == 'target' ? '对方' : '用户';
    lines.add('$i. [$who]: ${m['text']}');
  }
  var head = '以下是「用户」和「${targetName ?? '对方'}」的聊天记录，共 ${sample.length} 条。\n';
  if (offset > 0) {
    head += '（为控制长度，只取最近 ${sample.length} 条，序号从 $offset 开始）\n';
  }
  return '$head\n${lines.join('\n')}\n\n$distillOutputSpec';
}

Future<Map<String, dynamic>> callDistill(
    String prompt, Map<String, dynamic>? cfg) async {
  final raw = await complete(
    [
      {'role': 'system', 'content': distillSystemPrompt},
      {'role': 'user', 'content': prompt},
    ],
    temperature: 0.2,
    cfg: cfg,
    jsonMode: true,
  );
  try {
    return jsonDecode(raw) as Map<String, dynamic>;
  } catch (_) {
    final start = raw.indexOf('{');
    final end = raw.lastIndexOf('}');
    if (start >= 0 && end > start) {
      return jsonDecode(raw.substring(start, end + 1)) as Map<String, dynamic>;
    }
    throw LlmError('模型没返回合法 JSON：${raw.length > 500 ? raw.substring(0, 500) : raw}');
  }
}

/// 防幻觉校验：返回问题列表，空列表 = 通过。
List<String> validateDistill(Map<String, dynamic> profile, List<dynamic> messages) {
  final issues = <String>[];
  final msgs = ensureIndex(messages);
  final idx = <dynamic>{for (final m in msgs) m['i']};
  final byIdx = <dynamic, Map<String, dynamic>>{for (final m in msgs) m['i']: m};

  void checkRefs(String path, List<dynamic>? refs, {bool allowUser = false}) {
    for (final r in refs ?? const []) {
      if (!idx.contains(r)) {
        issues.add('$path: 引用了不存在的消息 #$r（幻觉）');
      } else if (byIdx[r]?['speaker'] != 'target' && !allowUser) {
        issues.add('$path: 消息 #$r 是用户说的，不是对方（证据用错人）');
      }
    }
  }

  final traits = profile['traits'] as List? ?? const [];
  for (var k = 0; k < traits.length; k++) {
    final t = traits[k] as Map? ?? {};
    final name = t['name']?.toString() ?? '?';
    checkRefs('traits[$k]($name)', t['evidence'] as List?);
    final ev = t['evidence'] as List? ?? const [];
    if (ev.isEmpty) {
      issues.add('traits[$k]($name): 无证据支撑');
    } else if (ev.length < 2) {
      issues.add('traits[$k]($name): 只有 1 条证据，可能是偶发而非性格');
    }
  }

  final flaws = profile['flaws'] as List? ?? const [];
  for (var k = 0; k < flaws.length; k++) {
    final f = flaws[k] as Map? ?? {};
    checkRefs('flaws[$k](${f['type']?.toString() ?? '?'})', f['evidence'] as List?);
  }
  if (flaws.isEmpty) {
    issues.add('flaws: 一条缺点都没找到，模型在美化，这份档案不可用');
  }

  // 关系看的是双方互动，允许引用用户的话；traits/flaws 描述「TA 是什么人」，必须只引对方
  checkRefs('relationship', (profile['relationship'] as Map?)?['evidence'] as List?,
      allowUser: true);

  final ss = profile['style_samples'] as List? ?? const [];
  for (var k = 0; k < ss.length; k++) {
    final s = ss[k] as Map? ?? {};
    final sit = s['situation']?.toString() ?? '?';
    checkRefs('style_samples[$k]($sit)', s['evidence'] as List?);
    if ((s['replies'] as List? ?? const []).isEmpty) {
      issues.add('style_samples[$k]($sit): 没有原话');
    }
  }
  for (final s in profile['flagged_samples'] as List? ?? const []) {
    if (s is Map && !idx.contains(s['index'])) {
      issues.add('flagged_samples: 引用了不存在的消息 #${s['index']}');
    }
  }

  if (msgs.length < 30) {
    issues.add('样本仅 ${msgs.length} 条，低于 30 条，结论可信度很低');
  }
  return issues;
}

/// 生成人工校准用的 Markdown：每条结论下面挂着原文，人对着看就行。
String renderReport(
    Map<String, dynamic> profile, List<dynamic> messages, List<String> issues) {
  final msgs = ensureIndex(messages);
  final byIdx = <dynamic, Map<String, dynamic>>{for (final m in msgs) m['i']: m};

  String cites(List<dynamic>? refs) {
    final out = <String>[];
    for (final r in refs ?? const []) {
      final m = byIdx[r];
      if (m != null) {
        final who = m['speaker'] == 'target' ? '对方' : '用户';
        out.add('  - #$r [$who] ${m['text']}');
      }
    }
    return out.isEmpty ? '  - （无有效引用）' : out.join('\n');
  }

  final L = <String>['# 人格档案校准报告 — ${profile['target_name'] ?? '?'}', ''];
  if (issues.isNotEmpty) {
    L.addAll(['## ⚠️ 校验问题', '', ...[for (final x in issues) '- $x'], '']);
  }

  L.addAll(['## 人格特质', '']);
  for (final t in profile['traits'] as List? ?? const []) {
    if (t is! Map) continue;
    L.addAll([
      '### ${t['name']} — 强度 ${t['weight']} / 置信 ${t['confidence']}',
      '',
      '${t['description'] ?? ''}',
      '',
      '证据：',
      cites(t['evidence'] as List?),
      '',
    ]);
  }

  L.addAll(['## 缺点', '']);
  for (final f in profile['flaws'] as List? ?? const []) {
    if (f is! Map) continue;
    L.addAll([
      '### ${f['type']} — 强度 ${f['intensity']}',
      '',
      '${f['description'] ?? ''}',
      '',
      '证据：',
      cites(f['evidence'] as List?),
      '',
    ]);
  }

  final st = profile['speech_style'] as Map? ?? {};
  L.addAll(['## 说话风格', '', ...[for (final k in st.keys) '- $k: ${st[k]}'], '']);

  final ss = profile['style_samples'] as List? ?? const [];
  if (ss.isNotEmpty) {
    L.addAll(['## 你会这么说（原话样本）', '']);
    for (final s in ss) {
      if (s is! Map) continue;
      L.add('### ${s['situation'] ?? '?'}');
      for (final r in s['replies'] as List? ?? const []) {
        L.add('> $r');
      }
      L.addAll(['', '证据：', cites(s['evidence'] as List?), '']);
    }
  }

  final kb = profile['knowledge_bounds'] as Map? ?? {};
  String joinList(List<dynamic>? v) =>
      (v ?? const []).isEmpty ? '（未识别）' : v!.join(', ');
  L.addAll([
    '## 知识边界',
    '',
    '- 懂：${joinList(kb['confident'] as List?)}',
    '- 半懂：${joinList(kb['shaky'] as List?)}',
    '- 不懂：${joinList(kb['clueless'] as List?)}',
    '',
  ]);

  final rel = profile['relationship'] as Map? ?? {};
  L.addAll([
    '## 与用户的关系',
    '',
    '- 性质：${rel['bond'] ?? ''}',
    '- 主动性：${rel['asymmetry'] ?? ''}',
    '',
  ]);

  final warnings = profile['warnings'] as List? ?? const [];
  if (warnings.isNotEmpty) {
    L.addAll(['## 模型自己标注的存疑点', '', ...[for (final w in warnings) '- $w'], '']);
  }
  return L.join('\n');
}

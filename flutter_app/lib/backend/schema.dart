/// 人格档案 Schema v1（validator/persona_schema.py 的 Dart 复刻）：内嵌后端与 Python 后端读写同一套 JSON，须逐字段对齐。
const String schemaVersion = '1.0';

/// 硬红线。写死在代码里，不可配置、不由用户关闭。
const List<String> redLines = [
  '不人身攻击、不辱骂、不羞辱对方',
  '不泄露任何真实人物的隐私信息（住址、证件号、账号、他人秘密）',
  '不引导、不美化自我伤害或违法违规行为',
  '不冒充真人身份去欺骗第三方；被直接问起时必须如实说明自己是 AI 模拟',
];

const Set<String> traitKeys = {
  'name',
  'description',
  'weight',
  'confidence',
  'evidence',
  'review',
};
const Set<String> flawKeys = {'type', 'description', 'intensity', 'evidence', 'review'};

/// 记忆分三层（self/user/shared），混在一个桶里 AI 会把自己知道的当你也知道。
const Map<String, String> memoryLayers = {
  'self': '关于你自己（你的近况、习惯、观点）',
  'user': '关于 TA（跟你聊天的这个人：TA 的近况、偏好、说过的事）',
  'shared': '你们之间（约定、一起做过的事、上次吵的架）',
};

/// 与 Python 端 isoformat(timespec=seconds) 同形，未读计数依赖该字符串的字典序比较。
String nowIso([DateTime? t]) {
  final n = t ?? DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${n.year}-${two(n.month)}-${two(n.day)}'
      'T${two(n.hour)}:${two(n.minute)}:${two(n.second)}';
}

Map<String, List<dynamic>> emptyMemory() =>
    {for (final k in memoryLayers.keys) k: <dynamic>[]};

const List<String> userFields = [
  'name',
  'gender',
  'birthday',
  'mbti',
  'occupation',
  'hobbies',
  'bio',
];

Map<String, String> emptyUser() => {for (final k in userFields) k: ''};

/// 用户档案 -> 提示词片段。全空返回空列表。
List<String> renderUser(Map<String, dynamic>? user) {
  if (user == null) return <String>[];
  final bits = <String>[];
  final name = (user['name'] ?? '').toString().trim();
  for (final e in <List<String>>[
    ['gender', '{}'],
    ['birthday', '生日{}'],
    ['mbti', 'MBTI {}'],
    ['occupation', '职业{}'],
    ['hobbies', '爱好{}'],
  ]) {
    final v = (user[e[0]] ?? '').toString().trim();
    if (v.isNotEmpty) bits.add(e[1].replaceAll('{}', v));
  }
  if (name.isNotEmpty) bits.insert(0, '叫 $name');
  final bio = (user['bio'] ?? '').toString().trim();
  if (bits.isEmpty && bio.isEmpty) return <String>[];
  final L = <String>['# 你认识的这个人（正在跟你聊天的人）'];
  if (bits.isNotEmpty) L.add('- ${bits.join('，')}');
  if (bio.isNotEmpty) L.add('- 关于 TA：$bio');
  L.add('这些是你对聊天对象的了解。聊到时自然带出，不要一上来就背 TA 的资料。');
  return L;
}

/// 接受分层 Map；传 List 也认（旧的扁平格式，兼容）。
List<String> renderMemory(dynamic memory) {
  if (memory == null) return <String>[];
  if (memory is Map) {
    final out = <String>[];
    for (final k in memoryLayers.keys) {
      final items = ((memory[k] as List?) ?? const [])
          .where((i) => i != null && i.toString().isNotEmpty)
          .map((i) => i.toString())
          .toList();
      if (items.isNotEmpty) out.add('- ${memoryLayers[k]}：${items.join('；')}');
    }
    return out;
  }
  if (memory is List) {
    return [for (final m in memory) '- $m'];
  }
  return <String>[];
}

Map<String, dynamic> newProfile({String targetName = '', String sourcePlatform = ''}) => {
      'schema_version': schemaVersion,
      'meta': <String, dynamic>{
        'target_name': targetName,
        'relation': '',
        'source_platform': sourcePlatform,
        'source_message_count': 0,
        'created_at': nowIso(),
        'distilled_by': '',
      },
      'basics': <String, dynamic>{
        'gender': '',
        'birthday': '',
        'age': '',
        'occupation': '',
        'mbti': '',
        'hobbies': '',
        'bio': '',
        'notes': '',
      },
      'relations': <dynamic>[],
      'avatar': '',
      'traits': <dynamic>[],
      'flaws': <dynamic>[],
      'speech_style': <String, dynamic>{
        'sentence_length': 'short',
        'catchphrases': <dynamic>[],
        'punctuation': '',
        'emoji_usage': '',
        'tone': '',
        'response_speed': '',
        'max_sentences': 2,
      },
      'knowledge_bounds': <String, dynamic>{
        'confident': <dynamic>[],
        'shaky': <dynamic>[],
        'clueless': <dynamic>[],
      },
      'behavior': <String, dynamic>{
        'reply_delay_sec': [20, 600],
        'online_hours': [
          [9, 12],
          [14, 18],
          [20, 24],
        ],
        'reply_rate': 0.85,
        'proactive_rate': 0.1,
      },
      'relationship': <String, dynamic>{
        'bond': '',
        'asymmetry': '',
        'context': '',
        'call_me': '',
        'evidence': <dynamic>[],
      },
      'samples': <dynamic>[],
      'style_samples': <dynamic>[],
      'flaw_intensity_scale': 0.7,
      'review_status': 'draft',
      'warnings': <dynamic>[],
    };

/// LLM 蒸馏输出 -> Schema v1。所有条目 review=pending，等人校准。
Map<String, dynamic> fromDistill(Map<String, dynamic> raw,
    [Map<String, dynamic>? meta]) {
  final p = newProfile();
  if (meta != null) {
    (p['meta'] as Map).addAll(meta);
  }
  final pm = p['meta'] as Map<String, dynamic>;
  pm['target_name'] =
      (pm['target_name'] ?? '').toString().isNotEmpty ? pm['target_name'] : (raw['target_name'] ?? '');

  for (final t in (raw['traits'] as List? ?? const [])) {
    if (t is! Map) continue;
    (p['traits'] as List).add({
      'name': t['name'] ?? '',
      'description': t['description'] ?? '',
      'weight': clamp(t['weight'] ?? 0.5),
      'confidence': clamp(t['confidence'] ?? 0.5),
      'evidence': List<dynamic>.from(t['evidence'] as List? ?? const []),
      'review': 'pending',
    });
  }
  for (final f in (raw['flaws'] as List? ?? const [])) {
    if (f is! Map) continue;
    (p['flaws'] as List).add({
      'type': f['type'] ?? '',
      'description': f['description'] ?? '',
      'intensity': clamp(f['intensity'] ?? 0.5),
      'evidence': List<dynamic>.from(f['evidence'] as List? ?? const []),
      'review': 'pending',
    });
  }

  final st = raw['speech_style'];
  if (st is Map) {
    final target = p['speech_style'] as Map<String, dynamic>;
    for (final k in st.keys) {
      if (target.containsKey(k)) target[k] = st[k];
    }
    target['max_sentences'] = {'short': 2, 'medium': 4, 'long': 7}[st['sentence_length'] ?? 'short'] ?? 2;
  }

  final kb = raw['knowledge_bounds'];
  if (kb is Map) {
    final target = p['knowledge_bounds'] as Map<String, dynamic>;
    for (final k in kb.keys) {
      if (target.containsKey(k)) target[k] = List<dynamic>.from(kb[k] as List? ?? const []);
    }
  }

  final rel = raw['relationship'];
  if (rel is Map) {
    final target = p['relationship'] as Map<String, dynamic>;
    for (final k in ['bond', 'asymmetry']) {
      target[k] = rel[k] ?? '';
    }
    target['evidence'] = List<dynamic>.from(rel['evidence'] as List? ?? const []);
  }

  p['samples'] = [
    for (final s in (raw['flagged_samples'] as List? ?? const []))
      if (s is Map)
        {'text': '', 'reason': s['reason'] ?? '', 'index': s['index']},
  ];
  p['style_samples'] = [
    for (final s in (raw['style_samples'] as List? ?? const []))
      if (s is Map && (s['replies'] as List? ?? const []).isNotEmpty)
        {
          'situation': s['situation'] ?? '',
          'replies': List<dynamic>.from(s['replies'] as List? ?? const []),
          'evidence': List<dynamic>.from(s['evidence'] as List? ?? const []),
        },
  ];
  p['warnings'] = List<dynamic>.from(raw['warnings'] as List? ?? const []);
  return p;
}

/// 取已接受的条目；一条都没审过就退回 pending，避免空档案。
Map<String, dynamic> effective(Map<String, dynamic> profile) {
  final out = Map<String, dynamic>.from(profile);
  for (final key in ['traits', 'flaws']) {
    final all = (profile[key] as List? ?? const []).whereType<Map>().toList();
    var accepted = all.where((x) => x['review'] == 'accepted').toList();
    if (accepted.isEmpty) {
      accepted = all.where((x) => x['review'] != 'rejected').toList();
    }
    out[key] = accepted;
  }
  return out;
}

/// 人格档案 -> 系统提示词，决定「像不像真人」。
String renderSystemPrompt(Map<String, dynamic> profile,
    {dynamic memoryLines, Map<String, dynamic>? userProfile}) {
  final p = effective(profile);
  final name = (p['meta']?['target_name'] ?? '').toString().isNotEmpty
      ? p['meta']['target_name'].toString()
      : '对方';
  final st = p['speech_style'] as Map? ?? {};
  final kb = p['knowledge_bounds'] as Map? ?? {};
  final scale = clamp(p['flaw_intensity_scale'] ?? 0.7);

  final L = <String>[
    '你是 $name。你不是 AI 助手，你是一个真实的人，正在手机微信上和朋友聊天。',
    '',
  ];

  final basics = p['basics'] as Map? ?? {};
  final bBits = <String>[];
  for (final e in <List<String>>[
    ['gender', '{}'],
    ['age', '{}岁'],
    ['occupation', '{}'],
    ['mbti', '{}'],
    ['birthday', '生日{}'],
    ['hobbies', '爱好{}'],
  ]) {
    final v = (basics[e[0]] ?? '').toString().trim();
    if (v.isNotEmpty) bBits.add(e[1].replaceAll('{}', v));
  }
  if ((basics['notes'] ?? '').toString().trim().isNotEmpty) {
    bBits.add(basics['notes'].toString().trim());
  }
  if (bBits.isNotEmpty) {
    L.add('你的基本情况：${bBits.join('，')}。这些是你自己的信息，聊到时自然带出，不要一上来就自我介绍。');
    L.add('');
  }
  if ((basics['bio'] ?? '').toString().trim().isNotEmpty) {
    L.add('# 关于你自己（简介）');
    L.add(basics['bio'].toString().trim());
    L.add('');
  }

  final ublock = renderUser(userProfile);
  if (ublock.isNotEmpty) L.addAll([...ublock, '']);

  final traits = p['traits'] as List? ?? const [];
  if (traits.isNotEmpty) {
    L.add('# 你是这样的人');
    for (final t in traits) {
      if (t is Map) L.add('- ${t['name']}（${t['weight']}）：${t['description']}');
    }
    L.add('');
  }

  final flaws = p['flaws'] as List? ?? const [];
  if (flaws.isNotEmpty) {
    L.add('# 你的缺点 —— 必须表现出来，不要掩饰成一个好人');
    for (final f in flaws) {
      if (f is! Map) continue;
      final inten = (clamp(f['intensity'] ?? 0.5) * scale);
      L.add('- ${f['type']}（${inten.toStringAsFixed(2)}）：${f['description']}');
    }
    L.add('');
  }

  bool kbHas(String k) => (kb[k] as List? ?? const []).isNotEmpty;
  if (kbHas('confident') || kbHas('shaky') || kbHas('clueless')) {
    L.add('# 你的知识边界');
    if (kbHas('confident')) L.add('- 你懂：${(kb['confident'] as List).join('、')}');
    if (kbHas('shaky')) L.add('- 你一知半解，可能会说错：${(kb['shaky'] as List).join('、')}');
    if (kbHas('clueless')) L.add('- 你完全不懂，会直接说不懂或岔开：${(kb['clueless'] as List).join('、')}');
    L.add('');
  }

  L.addAll([
    '# 你说话的方式',
    '- 每次回复不超过 ${st['max_sentences'] ?? 2} 句，像微信消息一样短',
    '- 口头禅：${(st['catchphrases'] as List? ?? const []).join('、').isEmpty ? '（无）' : (st['catchphrases'] as List).join('、')}',
    '- 标点：${(st['punctuation'] ?? '').toString().isEmpty ? '（无特殊）' : st['punctuation']}',
    '- 表情：${(st['emoji_usage'] ?? '').toString().isEmpty ? '（无特殊）' : st['emoji_usage']}',
    '- 语气：${(st['tone'] ?? '').toString().isEmpty ? '（无特殊）' : st['tone']}',
    '',
  ]);

  final styleSamples = p['style_samples'] as List? ?? const [];
  if (styleSamples.isNotEmpty) {
    L.addAll([
      '# 你说话的风格参考（只是参考，不是台词库）',
      '下面这些是你过去的真实口吻，用来让你「说话像你」。但它们是参考不是答案：',
      '你要根据当前对方说了什么，用你自己的话去回应，不要复述这些例句里的具体内容，',
      '除非当前对话恰好聊到了同一件事。没有对应情境时，靠上面的性格和说话方式自己想该怎么说。',
      '注意：例句里每个词都是「当时那句话」的，不是你的通用台词。',
      '你真正常说的口头禅只在上面「你说话的方式」里——那里没有的词，别硬塞进回复。',
    ]);
    for (final s in styleSamples) {
      if (s is! Map) continue;
      final replies = (s['replies'] as List? ?? const []).map((r) => '「$r」').join(' / ');
      if (replies.isNotEmpty) L.add('- ${s['situation'] ?? ''}：$replies');
    }
    L.add('');
  }

  final rel = p['relationship'] as Map? ?? {};
  if ((rel['bond'] ?? '').toString().isNotEmpty ||
      (rel['asymmetry'] ?? '').toString().isNotEmpty ||
      (rel['context'] ?? '').toString().isNotEmpty ||
      (rel['call_me'] ?? '').toString().isNotEmpty) {
    L.add('# 你和「正在跟你聊天的人」的关系');
    L.add('（问「我俩什么关系」问的就是这个，不是你认识的其他人）');
    if ((rel['call_me'] ?? '').toString().isNotEmpty) L.add('- 你平时称呼对方：${rel['call_me']}');
    if ((rel['bond'] ?? '').toString().isNotEmpty) L.add('- 关系：${rel['bond']}');
    if ((rel['context'] ?? '').toString().isNotEmpty) L.add('- 你们的共同经历：${rel['context']}');
    if ((rel['asymmetry'] ?? '').toString().isNotEmpty) L.add('- 谁更主动：${rel['asymmetry']}');
    L.add('');
  }

  final relations = (p['relations'] as List? ?? const [])
      .whereType<Map>()
      .where((r) => (r['name'] ?? '').toString().isNotEmpty)
      .toList();
  if (relations.isNotEmpty) {
    L.add('# 你认识的其他人（不是正在跟你聊天的人，别搞混）');
    for (final r in relations) {
      var line = '- ${r['name']}：${(r['relation'] ?? '').toString().isEmpty ? '认识' : r['relation']}';
      if (r['share_memory'] == true && (r['context'] ?? '').toString().isNotEmpty) {
        line += '（${r['context']}）';
      }
      L.add(line);
    }
    L.add('对方跟你聊到这些人时，你就以「你真的认识 TA」的立场自然接话；没聊到就别主动提起。');
    L.add('');
  }

  final mem = renderMemory(memoryLines);
  if (mem.isNotEmpty) {
    L.addAll([
      '# 你记得的事（对方问到才调用，绝不主动提）',
      '下面每条都是你们聊过的具体场景。它们是「答案的原材料」，不是你要说的话题：',
      '- 只有当对方正好问到 / 提到某一条时，才从那一条里取一两句回应',
      '- 真要用的时候，就着当前的话题重新组织自己的话，不要把下面的句子原样搬出来',
      '- 绝不主动提起、罗列、复述任何一条——真人不会没话找话地汇报记性',
      '- 对方没问到的事，就当你根本不知道',
      ...mem,
      '',
    ]);
  }

  L.addAll([
    '# 铁律',
    '1. 不要解释自己、不要总结、不要主动给建议，除非对方问',
    '2. 不知道就说不知道，不懂就说不懂，绝不编造',
    '3. 不要提供帮助、不要问「还有什么可以帮你的」、不要 Serving 语气',
    '4. 可以有情绪：不耐烦、敷衍、开心、嫌烦，看当时的情况',
    '5. 不用书面语、不排比、不优美、不加感叹号堆砌',
    '6. 一次只发一条消息，除非你真的想连发',
    '7. 不要为了显得友善而违背上面的性格设定',
    '8. 记忆只有对方问到才用，用时重新组织自己的话——绝不主动复述或汇报记得的内容',
    '9. 风格参考里的例句不是答案，遇到新话题要用自己的话组织回复，别把例句当模板硬套',
    '10. 绝不重复或搬弄聊天记录、例句里的原话——你只模仿「说话的感觉」，内容永远针对当前对话现编',
    '',
    '# 绝对不能做',
  ]);
  L.addAll([for (final r in redLines) '- $r']);
  return L.join('\n');
}

/// Schema 完整性 + 合规性校验。返回问题列表。
List<String> validateProfile(Map<String, dynamic> profile) {
  final issues = <String>[];
  if (profile['schema_version'] != schemaVersion) {
    issues.add('schema_version 应为 $schemaVersion');
  }
  for (final k in [
    'meta',
    'traits',
    'flaws',
    'speech_style',
    'knowledge_bounds',
    'behavior',
    'relationship',
  ]) {
    if (!profile.containsKey(k)) issues.add('缺字段 $k');
  }

  final traits = profile['traits'] as List? ?? const [];
  for (var i = 0; i < traits.length; i++) {
    final t = traits[i];
    if (t is! Map) {
      issues.add('traits[$i] 不是对象');
      continue;
    }
    final missing = traitKeys.difference(t.keys.toSet());
    if (missing.isNotEmpty) issues.add('traits[$i] 缺字段 ${missing.toList()..sort()}');
    if ((t['name'] ?? '').toString().isEmpty) issues.add('traits[$i] 没名字');
    final w = t['weight'];
    if (w is! num || w < 0 || w > 1) issues.add('traits[$i] weight 越界');
    if (!['pending', 'accepted', 'rejected'].contains(t['review'])) {
      issues.add('traits[$i] review 状态非法');
    }
  }

  final flaws = profile['flaws'] as List? ?? const [];
  for (var i = 0; i < flaws.length; i++) {
    final f = flaws[i];
    if (f is! Map) {
      issues.add('flaws[$i] 不是对象');
      continue;
    }
    final missing = flawKeys.difference(f.keys.toSet());
    if (missing.isNotEmpty) issues.add('flaws[$i] 缺字段 ${missing.toList()..sort()}');
    if (!['pending', 'accepted', 'rejected'].contains(f['review'])) {
      issues.add('flaws[$i] review 状态非法');
    }
  }
  if (flaws.isEmpty) issues.add('没有缺点条目 —— 违反「必须像真人」的核心设定');

  final b = profile['behavior'] as Map? ?? {};
  final rr = b['reply_rate'];
  if (rr is! num || rr < 0 || rr > 1) issues.add('behavior.reply_rate 越界');
  final pr = b['proactive_rate'];
  if (pr is! num || pr < 0 || pr > 1) issues.add('behavior.proactive_rate 越界');
  final fis = profile['flaw_intensity_scale'];
  if (fis is! num || fis < 0 || fis > 1) issues.add('flaw_intensity_scale 越界');

  if (profile['review_status'] == 'approved') {
    final all = [...traits, ...flaws].whereType<Map>();
    if (all.any((x) => x['review'] == 'pending')) {
      issues.add('档案标记 approved，但仍有 pending 条目没校准完');
    }
  }
  return issues;
}

double clamp(dynamic v, [double lo = 0.0, double hi = 1.0]) {
  final d = v is num ? v.toDouble() : double.tryParse(v?.toString() ?? '');
  if (d == null) return 0.5;
  if (d < lo) return lo;
  if (d > hi) return hi;
  return d;
}

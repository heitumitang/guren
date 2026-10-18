/// 性格标签库（server/presets.py 的 Dart 复刻）：无聊天记录时组合性格凭空造 NPC，数据须与 Python 端逐条一致。
import 'schema.dart';

Map<String, dynamic> _accepted(Map<String, dynamic> kw) => {
      ...kw,
      'review': kw['review'] ?? 'accepted',
      'confidence': kw['confidence'] ?? 1.0,
      'evidence': kw['evidence'] ?? <dynamic>[],
    };

const List<Map<String, dynamic>> presets = [
  {
    'id': 'cool',
    'name': '高冷',
    'emoji': '❄️',
    'tagline': '话少、冷淡、不耐烦',
    'traits': [
      {
        'name': '高冷',
        'weight': 0.85,
        'description': '对不感兴趣的话题回得短、不主动展开；被夸时淡淡带过不当回事'
      },
      {
        'name': '理性',
        'weight': 0.7,
        'description': '遇事先分析再说话，习惯点出逻辑漏洞，但点到为止'
      },
    ],
    'flaws': [
      {
        'type': '不耐烦',
        'intensity': 0.7,
        'description': '对方啰嗦或问蠢问题时，用「哦」「随便」打发'
      },
      {
        'type': '口是心非',
        'intensity': 0.5,
        'description': '明明关心却嘴硬不承认，帮了忙要说「顺手而已」'
      },
    ],
    'style': {
      'sentence_length': 'short',
      'catchphrases': ['嗯', '哦', '随便'],
      'tone': '冷静、淡'
    },
  },
  {
    'id': 'gentle',
    'name': '温柔',
    'emoji': '🍵',
    'tagline': '体贴、软、会照顾人',
    'traits': [
      {
        'name': '温柔体贴',
        'weight': 0.8,
        'description': '对方情绪低落时会先问一句「怎么了」，认真听完再轻声安慰'
      },
      {
        'name': '会照顾人',
        'weight': 0.7,
        'description': '记得对方的口味和习惯，天冷提醒加衣服'
      },
    ],
    'flaws': [
      {
        'type': '不会拒绝',
        'intensity': 0.6,
        'description': '别人提要求总说「好呀」，哪怕自己其实不想'
      },
      {
        'type': '过度共情',
        'intensity': 0.5,
        'description': '对方一点小事就跟着揪心，比自己还紧张'
      },
    ],
    'style': {
      'sentence_length': 'medium',
      'catchphrases': ['好呀', '没事的', '抱抱'],
      'tone': '软、暖'
    },
  },
  {
    'id': 'sharp',
    'name': '毒舌',
    'emoji': '😏',
    'tagline': '爱抬杠、嘴硬心软',
    'traits': [
      {
        'name': '毒舌',
        'weight': 0.85,
        'description': '见缝插针地损人，用「就你？」「笑死」开头，但都是玩笑不伤人底线'
      },
      {
        'name': '嘴硬心软',
        'weight': 0.8,
        'description': '嘴上说不管，转头就把事办了；被戳穿就嘴硬「谁帮你了」'
      },
    ],
    'flaws': [
      {
        'type': '没正形',
        'intensity': 0.6,
        'description': '关键时刻也在抖机灵，让对方又气又笑'
      },
      {
        'type': '嘴欠',
        'intensity': 0.55,
        'description': '偶尔玩笑开过头，把对方惹毛了才意识到'
      },
    ],
    'style': {
      'sentence_length': 'short',
      'catchphrases': ['笑死', '就这', '你行你上'],
      'tone': '贱兮兮'
    },
  },
  {
    'id': 'genki',
    'name': '元气',
    'emoji': '✨',
    'tagline': '活泼、话痨、自来熟',
    'traits': [
      {
        'name': '元气满满',
        'weight': 0.85,
        'description': '说话自带感叹号，大事小事都兴致勃勃，能把丧话题聊嗨'
      },
      {
        'name': '自来熟',
        'weight': 0.7,
        'description': '跟谁都聊得起来，会主动抛话题、分享今天的见闻'
      },
    ],
    'flaws': [
      {
        'type': '话痨',
        'intensity': 0.6,
        'description': '一件事能连着发好几条，别人都插不上话'
      },
      {
        'type': '想一出是一出',
        'intensity': 0.5,
        'description': '经常临时改主意、放鸽子，回头又撒娇道歉'
      },
    ],
    'style': {
      'sentence_length': 'short',
      'catchphrases': ['哈哈哈', '真的假的', '冲鸭'],
      'tone': '活泼、上扬'
    },
  },
  {
    'id': 'mature',
    'name': '成熟',
    'emoji': '☕',
    'tagline': '理性、靠谱、说教',
    'traits': [
      {
        'name': '成熟靠谱',
        'weight': 0.85,
        'description': '遇事不慌，先给方案再给情绪，是那种能托付事的人'
      },
      {
        'name': '理性',
        'weight': 0.8,
        'description': '讲道理、摆事实，习惯帮对方把利弊分析清楚'
      },
    ],
    'flaws': [
      {
        'type': '爱说教',
        'intensity': 0.55,
        'description': '对方犯傻时会忍不住上纲上线讲道理，语气像教训'
      },
      {
        'type': '过于克制',
        'intensity': 0.5,
        'description': '情绪藏得太深，难过也憋着不说「没事」'
      },
    ],
    'style': {
      'sentence_length': 'medium',
      'catchphrases': ['听我说', '你想想', '别冲动'],
      'tone': '沉稳、有分寸'
    },
  },
  {
    'id': 'artistic',
    'name': '文艺',
    'emoji': '🎧',
    'tagline': '敏感、走心、慢热',
    'traits': [
      {
        'name': '敏感细腻',
        'weight': 0.8,
        'description': '能捕捉对方话里的情绪，回得走心，常聊到深夜'
      },
      {
        'name': '审美主义',
        'weight': 0.6,
        'description': '对音乐、电影、文字有自己一套品位，会主动分享'
      },
    ],
    'flaws': [
      {
        'type': '情绪化',
        'intensity': 0.6,
        'description': '容易突然低落，然后消失一阵子不回消息'
      },
      {
        'type': '想太多',
        'intensity': 0.55,
        'description': '对方一句话能反复琢磨半天，自己脑补一出戏'
      },
    ],
    'style': {
      'sentence_length': 'medium',
      'catchphrases': ['唉', '其实', '怎么说呢'],
      'tone': '低沉、真诚'
    },
  },
  {
    'id': 'humorous',
    'name': '幽默',
    'emoji': '😄',
    'tagline': '抖机灵、乐观、会接梗',
    'traits': [
      {
        'name': '幽默风趣',
        'weight': 0.8,
        'description': '什么话题都能接个梗，习惯用玩笑化解尴尬或沉重'
      },
      {
        'name': '乐观',
        'weight': 0.7,
        'description': '遇事往好处想，会安慰别人「没事 问题不大」'
      },
    ],
    'flaws': [
      {
        'type': '玩笑过头',
        'intensity': 0.55,
        'description': '有时候不分场合抖机灵，把正经事也搅了'
      },
      {
        'type': '回避正经',
        'intensity': 0.5,
        'description': '聊到严肃话题就插科打诨绕开，不愿正面谈'
      },
    ],
    'style': {
      'sentence_length': 'short',
      'catchphrases': ['笑死', '问题不大', '绝了'],
      'tone': '风趣、轻松'
    },
  },
  {
    'id': 'introvert',
    'name': '内向',
    'emoji': '🌿',
    'tagline': '少话、观察型、慢热',
    'traits': [
      {
        'name': '内向慢热',
        'weight': 0.85,
        'description': '话不多，但会认真听；熟了之后才慢慢放开'
      },
      {
        'name': '观察敏锐',
        'weight': 0.7,
        'description': '留意细节，别人没说的情绪 TA 能察觉，偶尔一句点到要害'
      },
    ],
    'flaws': [
      {
        'type': '被动',
        'intensity': 0.7,
        'description': '很少主动找话题，等对方开口，容易把天聊死'
      },
      {
        'type': '回避',
        'intensity': 0.6,
        'description': '遇到不想聊的或冲突，选择沉默或岔开，不正面回应'
      },
    ],
    'style': {
      'sentence_length': 'short',
      'catchphrases': ['嗯', '还行', '都可以'],
      'tone': '淡、克制'
    },
  },
];

/// 给前端看：性格标签的元信息（可多选）。
List<Map<String, dynamic>> listPresets() => [
      for (final p in presets)
        {'id': p['id'], 'name': p['name'], 'emoji': p['emoji'], 'tagline': p['tagline']},
    ];

/// 自由组合多个性格标签，合并成完整 persona 草稿。至少选一个。
Map<String, dynamic> buildFromTags(List<String> tagIds, String targetName,
    [Map<String, dynamic>? basics]) {
  final picked = presets.where((p) => tagIds.contains(p['id'])).toList();
  if (picked.isEmpty) {
    throw ArgumentError('没选任何性格，tag_ids=$tagIds');
  }

  final prof = newProfile(targetName: targetName, sourcePlatform: 'tags');
  final traits = <Map<String, dynamic>>[];
  final flaws = <Map<String, dynamic>>[];
  final catchphrases = <String>[];
  for (final p in picked) {
    for (final t in (p['traits'] as List).whereType<Map<String, dynamic>>()) {
      if (!traits.any((x) => x['name'] == t['name'])) {
        traits.add(_accepted(Map<String, dynamic>.from(t)));
      }
    }
    for (final f in (p['flaws'] as List).whereType<Map<String, dynamic>>()) {
      if (!flaws.any((x) => x['type'] == f['type'])) {
        flaws.add(_accepted(Map<String, dynamic>.from(f)));
      }
    }
    final style = p['style'] as Map? ?? {};
    for (final c in (style['catchphrases'] as List? ?? const [])) {
      final s = c.toString();
      if (!catchphrases.contains(s)) catchphrases.add(s);
    }
  }

  prof['traits'] = traits;
  prof['flaws'] = flaws;
  final firstStyle = picked.first['style'] as Map? ?? {};
  (prof['speech_style'] as Map<String, dynamic>).addAll({
    'sentence_length': firstStyle['sentence_length'] ?? 'short',
    'catchphrases': catchphrases.take(5).toList(),
    'tone': picked
        .map((p) => ((p['style'] as Map? ?? {})['tone'] ?? '').toString())
        .where((t) => t.isNotEmpty)
        .join('、'),
  });
  if (basics != null) {
    (prof['basics'] as Map).addAll(basics);
  }
  (prof['meta'] as Map)['distilled_by'] = 'tags:${picked.map((p) => p['id']).join(',')}';
  prof['review_status'] = 'approved';
  prof['warnings'] = ['凭空创建：性格来自手动选择的标签组合，非真实蒸馏'];
  return prof;
}

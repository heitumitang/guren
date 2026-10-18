/// 聊天记录导入解析器。
///
/// 把用户粘贴的聊天导出解析成后端 /distill 认识的 messages：
///   [{"i": 序号, "speaker": "target"|"user", "text": "内容"}]
///
/// 支持两种常见导出格式（可混用、自动续接）：
///   1. 微信/QQ 导出：「名字 12:30」单独一行，下面是内容（可多行）
///   2. 单行式：「名字：内容」
/// 说话人判定：与 TA 名字精确匹配 → target；其余 → user。
library;

class ImportMessage {
  final int i;
  final String speaker; // 'target' | 'user'
  final String text;
  ImportMessage({required this.i, required this.speaker, required this.text});

  Map<String, dynamic> toJson() => {'i': i, 'speaker': speaker, 'text': text};
}

class ParsedExport {
  final List<ImportMessage> messages;
  final List<String> speakers; // 识别到的说话人（按出现顺序）
  final String targetSpeaker; // 最终判定为 TA 的说话人名
  ParsedExport(this.messages, this.speakers, this.targetSpeaker);

  int get nTarget => messages.where((m) => m.speaker == 'target').length;
}

// 「名字 12:30」/「名字 12:30:45」/「名字 2024-01-01 12:30」/「名字 3:05 PM」
final _timeHeader = RegExp(
  r'^(.{1,24}?)\s+(\d{1,2}:\d{2}(:\d{2})?(\s*[APap][Mm])?'
  r'|\d{4}[-/]\d{1,2}[-/]\d{1,2}(\s+\d{1,2}:\d{2}(:\d{2})?)?)$',
);

// 「名字：内容」（名字里不含冒号/标点，限 20 字以内）
final _colonPrefix = RegExp(r'^([^：:，。！？,,.!?\n]{1,20})[：:]\s*(.*)$');

/// 解析聊天导出。[targetName] 是 TA 的名字（用于区分对话双方）；
/// [userName] 是用户自己的名字（可选，只在无法精确匹配时辅助判定）。
ParsedExport parseChatExport(String raw, String targetName,
    {String userName = ''}) {
  final entries = <MapEntry<String, String>>[]; // speaker -> text（续接行会拼进上一条）

  for (final line in raw.split(RegExp(r'\r?\n'))) {
    final t = line.trim();
    if (t.isEmpty) continue;

    String? speaker;
    var text = t;

    final h = _timeHeader.firstMatch(t);
    if (h != null) {
      final name = h.group(1)!.trim();
      // 头部行只贡献说话人，内容在后续行；名字明显不像名字（纯数字等）时按内容处理
      if (name.isNotEmpty && !RegExp(r'^\d+$').hasMatch(name)) {
        speaker = name;
        text = '';
      }
    }
    if (speaker == null) {
      final c = _colonPrefix.firstMatch(t);
      if (c != null && c.group(2)!.trim().isNotEmpty) {
        speaker = c.group(1)!.trim();
        text = c.group(2)!.trim();
      }
    }
    if (speaker == null) {
      // 续接行：拼到上一条内容后面；没有上一条（导出文件头）就忽略
      if (entries.isNotEmpty) {
        final last = entries.removeLast();
        entries.add(MapEntry(last.key, '${last.value}\n$t'.trim()));
      }
      continue;
    }
    entries.add(MapEntry(speaker, text));
  }

  // 两条头部行相邻（中间没内容）会产生空条目，丢掉
  entries.removeWhere((e) => e.value.trim().isEmpty);

  final speakers = <String>[];
  for (final e in entries) {
    if (!speakers.contains(e.key)) speakers.add(e.key);
  }

  final want = targetName.trim();
  var target = speakers.firstWhere((s) => s == want, orElse: () => '');
  if (target.isEmpty && speakers.length == 2) {
    // 两个说话人且没匹配上：排除用户自己的名字，剩下的是 TA
    target =
        speakers.firstWhere((s) => s != userName.trim(), orElse: () => '');
  } else if (target.isEmpty && speakers.isNotEmpty) {
    target = speakers.first;
  }

  final msgs = <ImportMessage>[];
  for (var i = 0; i < entries.length; i++) {
    msgs.add(ImportMessage(
      i: i,
      speaker: entries[i].key == target ? 'target' : 'user',
      text: entries[i].value,
    ));
  }
  return ParsedExport(msgs, speakers, target);
}

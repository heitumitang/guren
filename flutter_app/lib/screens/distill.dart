/// 蒸馏向导：导入聊天记录 → 蒸馏 → 校准。对齐 Web 版三步体验。
///
///   第 1 步 导入：粘贴聊天导出文本，或选聊天截图走 OCR（≥10 条才能蒸馏）
///   第 2 步 蒸馏：填 TA 的名字/头像/性别/关系，POST /distill
///   第 3 步 校准：逐条勾选特质/缺点，拖缺点强度滑块，POST /review + /scale
///
/// 完成后 pop 返回 npc_id，由人物列表打开聊天。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import '../chat_import.dart';
import '../models.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets.dart';

const _kEmojis = ['🙂', '😊', '😎', '🤔', '🥲', '😴', '😤', '🦊', '🐱', '🐶', '🌙', '☕'];

class DistillWizard extends StatefulWidget {
  const DistillWizard({super.key});

  @override
  State<DistillWizard> createState() => _DistillWizardState();
}

class _DistillWizardState extends State<DistillWizard> {
  int _step = 0; // 0 导入 / 1 蒸馏 / 2 校准

  // —— 第 1 步：导入 ——
  bool _ocrMode = false;

  /// 截图 OCR 依赖 Python 版的 RapidOCR；手机端跑的是 App 内置后端，没有 OCR。
  bool get _ocrSupported => !(Platform.isAndroid || Platform.isIOS);
  final _textCtl = TextEditingController();
  final _taNameCtl = TextEditingController();
  final _picker = ImagePicker();
  List<XFile> _images = [];
  String _side = 'left';
  List<ImportMessage> _msgs = [];
  String? _importErr;

  // —— 第 2 步：蒸馏 ——
  /// 合规确认：这些聊天记录来自真人，蒸馏会把它发给模型服务商。
  /// 每次导入都要重新勾（不持久化），因为每换一个人就是换一个数据主体。
  bool _consent = false;
  String _emoji = '🙂';
  String _avatarData = ''; // 图片头像 data URL
  final _genderCtl = TextEditingController();
  final _relCtl = TextEditingController();
  DistillResult? _result;
  Persona? _persona;

  // —— 第 3 步：校准 ——
  final Map<String, bool> _accept = {}; // 't0'/'f1' -> 是否保留
  double _flawScale = 0.7;

  bool _busy = false;
  int _tipIdx = 0;
  Timer? _tipTimer;

  @override
  void dispose() {
    _tipTimer?.cancel();
    _textCtl.dispose();
    _taNameCtl.dispose();
    _genderCtl.dispose();
    _relCtl.dispose();
    super.dispose();
  }

  // ---------------- 通用 ----------------

  void _startBusy(List<String> tips) {
    _tipIdx = 0;
    _tipTimer?.cancel();
    _tipTimer = Timer.periodic(const Duration(milliseconds: 1200), (_) {
      if (mounted) setState(() => _tipIdx = (_tipIdx + 1) % tips.length);
    });
    setState(() => _busy = true);
  }

  void _stopBusy() {
    _tipTimer?.cancel();
    _tipTimer = null;
    if (mounted) setState(() => _busy = false);
  }

  String _friendlyError(Object e) {
    final m = e.toString();
    if (RegExp(r'401|invalid|Authentication|无效').hasMatch(m)) {
      return 'API key 无效 —— 去「设置」检查 key';
    }
    if (m.contains('No address associated with hostname') ||
        m.contains('Connection refused') ||
        m.contains('Failed host lookup')) {
      return '连不上后端 —— 去「设置」检查地址';
    }
    return m.replaceFirst('Exception: ', '');
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  // ---------------- 第 1 步：导入 ----------------

  void _parseText() {
    final name = _taNameCtl.text.trim();
    if (name.isEmpty) {
      setState(() => _importErr = '先填 TA 的名字——解析时要靠它区分对话双方');
      return;
    }
    final s = context.read<AppState>();
    final parsed = parseChatExport(_textCtl.text, name, userName: s.user.name);
    if (parsed.messages.isEmpty) {
      setState(() => _importErr =
          '没识别出对话。支持两种格式：「名字 12:30」单独一行下面是内容；'
          '或每行一条「名字：内容」。');
      return;
    }
    setState(() {
      _msgs = parsed.messages;
      _importErr = null;
      _consent = false; // 换一批记录 = 换一次确认
    });
  }

  Future<void> _pickImages() async {
    try {
      final picked = await _picker.pickMultiImage();
      if (picked.isNotEmpty && mounted) {
        setState(() => _images = picked);
      }
    } catch (e) {
      _toast('这个平台暂时不能选图：$e');
    }
  }

  Future<void> _runOcr() async {
    if (_images.isEmpty) {
      _toast('先选截图');
      return;
    }
    final s = context.read<AppState>();
    _startBusy(['正在读图…', '识别气泡…', '拼接长图…', '区分双方…']);
    setState(() => _importErr = null);
    try {
      final b64s = <String>[];
      for (final x in _images) {
        b64s.add(base64Encode(await x.readAsBytes()));
      }
      final r = await s.api.ocr(b64s, targetSide: _side);
      final msgs = r.messages
          .map((m) => ImportMessage(
                i: (m as Map)['i'] as int? ?? 0,
                speaker: (m['speaker'] ?? 'user').toString(),
                text: (m['text'] ?? '').toString(),
              ))
          .toList();
      setState(() {
        _msgs = msgs;
        _importErr = r.warn;
        _consent = false; // 换一批记录 = 换一次确认
      });
      if (msgs.length < 10) {
        setState(() => _importErr =
            '识别到的消息太少（${msgs.length} 条），没法蒸馏。多半是 TA 气泡方向选反了，或截图不清晰。');
      }
    } catch (e) {
      final msg = _friendlyError(e);
      setState(() => _importErr = msg.contains('内置后端不支持')
          ? '手机端不支持截图 OCR，请改用「粘贴文本」导入。'
          : '识别失败：$msg。电脑整包版已内置 OCR，如仍失败请重启应用。');
    } finally {
      _stopBusy();
    }
  }

  // ---------------- 第 2 步：蒸馏 ----------------

  Future<void> _pickAvatar() async {
    try {
      final x = await _picker.pickImage(source: ImageSource.gallery);
      if (x == null || !mounted) return;
      final b64 = base64Encode(await x.readAsBytes());
      setState(() => _avatarData = 'data:image/png;base64,$b64');
    } catch (e) {
      _toast('这个平台暂时不能选图：$e');
    }
  }

  Future<void> _runDistill() async {
    if (!_consent) {
      _toast('先勾选下面那条使用确认');
      return;
    }
    final name = _taNameCtl.text.trim();
    if (name.isEmpty) {
      _toast('先填 TA 的名字');
      return;
    }
    if (_msgs.length < 10) {
      _toast('消息太少（${_msgs.length} 条），至少 10 条才能蒸馏');
      return;
    }
    final s = context.read<AppState>();
    _startBusy(['正在整理人格…', '提炼特质…', '寻找缺点…', '核对证据…']);
    try {
      final r = await s.api.distill(
        messages: _msgs.map((m) => m.toJson()).toList(),
        targetName: name,
        emoji: _emoji,
        avatar: _avatarData,
        basics: {'gender': _genderCtl.text.trim()},
        relation: _relCtl.text.trim(),
        llm: s.llm,
      );
      final persona = await s.api.getCharacter(r.id);
      if (!mounted) return;
      setState(() {
        _result = r;
        _persona = persona;
        _flawScale = persona.flawScale;
        _accept.clear();
        for (var i = 0; i < persona.traits.length; i++) {
          _accept['t$i'] = true;
        }
        for (var i = 0; i < persona.flaws.length; i++) {
          _accept['f$i'] = true;
        }
        _step = 2;
      });
    } catch (e) {
      _toast('蒸馏失败：${_friendlyError(e)}');
    } finally {
      _stopBusy();
    }
  }

  // ---------------- 第 3 步：校准 ----------------

  Future<void> _submitReview() async {
    final p = _persona;
    if (p == null) return;
    setState(() => _busy = true);
    final s = context.read<AppState>();
    try {
      final traits = <String, String>{};
      final flaws = <String, String>{};
      for (var i = 0; i < p.traits.length; i++) {
        final t = p.traits[i] as Map;
        traits[(t['name'] ?? '').toString()] =
            (_accept['t$i'] ?? true) ? 'accepted' : 'rejected';
      }
      for (var i = 0; i < p.flaws.length; i++) {
        final f = p.flaws[i] as Map;
        flaws[(f['type'] ?? '').toString()] =
            (_accept['f$i'] ?? true) ? 'accepted' : 'rejected';
      }
      await s.api.review(_result!.id, traits, flaws);
      await s.api.scale(_result!.id, _flawScale);
      await s.refreshCharacters();
      if (!mounted) return;
      Navigator.pop(context, _result!.id);
    } catch (e) {
      _toast('保存失败：${_friendlyError(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---------------- UI ----------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('蒸馏向导'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            if (_step > 0 && !_busy) {
              setState(() => _step--);
            } else {
              Navigator.pop(context);
            }
          },
        ),
      ),
      body: Column(
        children: [
          _stepBar(),
          if (_busy)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: LinearProgressIndicator(
                  color: kWechatGreen, backgroundColor: kWechatGreenSoft),
            ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              child: switch (_step) {
                0 => _buildImport(),
                1 => _buildDistill(),
                _ => _buildReview(),
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _stepBar() {
    final labels = ['导入', '蒸馏', '校准'];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(
        children: List.generate(3, (i) {
          final active = i <= _step;
          return Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: Column(
                children: [
                  Container(
                    height: 4,
                    decoration: BoxDecoration(
                      color: active ? kWechatGreen : kLine,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text('${i + 1} · ${labels[i]}',
                      style: TextStyle(
                          fontSize: 12,
                          color: active ? kWechatGreen : Colors.grey)),
                ],
              ),
            ),
          );
        }),
      ),
    );
  }

  // —— 第 1 步 ——

  Widget _buildImport() {
    final connected = context.watch<AppState>().connected;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!connected)
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: kWechatGreenSoft.withOpacity(0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Text('连不上后端——先去「设置」检查地址，再回来蒸馏。',
                style: TextStyle(color: kWechatGreen)),
          ),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('粘贴文本')),
            ButtonSegment(value: true, label: Text('截图 OCR')),
          ],
          selected: {_ocrMode},
          onSelectionChanged: (v) => setState(() {
            _ocrMode = v.first && _ocrSupported;
            _importErr = null;
          }),
        ),
        if (!_ocrSupported)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text(
              '手机端不支持截图 OCR（内置后端不跑 Python），请用「粘贴文本」导入聊天记录。',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
        const SizedBox(height: 12),
        if (!_ocrMode) _buildPaste(),
        if (_ocrMode) _buildOcr(),
        if (_importErr != null) ...[
          const SizedBox(height: 10),
          Text(_importErr!, style: const TextStyle(color: kWechatGreen)),
        ],
        if (_msgs.isNotEmpty) ...[
          const SizedBox(height: 12),
          _buildPreview(),
        ],
        const SizedBox(height: 16),
        ElevatedButton(
          onPressed: _busy || _msgs.length < 10
              ? null
              : () => setState(() => _step = 1),
          child: Text(_msgs.length < 10
              ? '至少需要 10 条消息（当前 ${_msgs.length}）'
              : '下一步 · 蒸馏（${_msgs.length} 条）'),
        ),
      ],
    );
  }

  Widget _buildPaste() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('01 · 粘贴聊天记录',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            const Text('微信/QQ 的聊天导出直接粘进来。支持「名字 12:30」加内容、'
                '或每行「名字：内容」两种格式，可混用。',
                style: TextStyle(fontSize: 13, color: Colors.grey)),
            const SizedBox(height: 12),
            TextField(
              controller: _taNameCtl,
              decoration: const InputDecoration(labelText: 'TA 叫什么 *'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _textCtl,
              maxLines: 8,
              minLines: 5,
              decoration: const InputDecoration(
                labelText: '聊天记录',
                alignLabelWithHint: true,
                hintText: '张三 12:30\n在吗\n李四 12:31\n在，怎么了',
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _busy ? null : _parseText, child: const Text('解析')),
          ],
        ),
      ),
    );
  }

  Widget _buildOcr() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('01 · 上传聊天截图',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            const Text('微信/QQ 聊天页长截图，可多选，滚动重叠会自动去重。',
                style: TextStyle(fontSize: 13, color: Colors.grey)),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                OutlinedButton.icon(
                  onPressed: _busy ? null : _pickImages,
                  icon: const Icon(Icons.photo_library),
                  label: Text(_images.isEmpty ? '选择图片' : '已选 ${_images.length} 张'),
                ),
                ChoiceChip(
                  label: const Text('TA 在左'),
                  selected: _side == 'left',
                  selectedColor: kWechatGreenSoft.withOpacity(0.35),
                  onSelected: (_) => setState(() => _side = 'left'),
                ),
                ChoiceChip(
                  label: const Text('TA 在右'),
                  selected: _side == 'right',
                  selectedColor: kWechatGreenSoft.withOpacity(0.35),
                  onSelected: (_) => setState(() => _side = 'right'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: _busy ? null : _runOcr,
              child: const Text('识别截图'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPreview() {
    final nT = _msgs.where((m) => m.speaker == 'target').length;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('共 ${_msgs.length} 条（TA $nT / 你 ${_msgs.length - nT}）',
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            SizedBox(
              height: 240,
              child: ListView.builder(
                itemCount: _msgs.length,
                itemBuilder: (_, i) {
                  final m = _msgs[i];
                  final mine = m.speaker == 'user';
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 34,
                          child: Text(mine ? '你' : 'TA',
                              style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: mine ? Colors.grey : kWechatGreen)),
                        ),
                        Expanded(
                          child: Text(m.text,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 13)),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  // —— 第 2 步 ——

  /// 使用确认：蒸馏会把聊天记录整段发给模型服务商，这是数据离开本机的一步，
  /// 必须让人在这里停一下。设计文档把「真实人物数据」列为高风险项。
  Widget _buildConsent() {
    return Card(
      color: kWechatGreen.withOpacity(0.06),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Checkbox(
              value: _consent,
              activeColor: kWechatGreen,
              onChanged: _busy ? null : (v) => setState(() => _consent = v ?? false),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 12, bottom: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    Text('这些人是我自己的聊天记录，或已获得对方同意',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                    SizedBox(height: 3),
                    Text(
                      '勾选即确认：只作私人纪念，不用于冒充他人或误导第三方。'
                      '点「开始蒸馏」后，这些记录会发给你在设置里填的模型服务商进行分析。',
                      style: TextStyle(fontSize: 12, height: 1.35),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDistill() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('02 · TA 是谁',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Avatar(emoji: _emoji, imageUrl: _avatarData, size: 56),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: _kEmojis.map((e) {
                          final sel = _emoji == e && _avatarData.isEmpty;
                          return ChoiceChip(
                            label: Text(e),
                            selected: sel,
                            selectedColor: kWechatGreenSoft.withOpacity(0.35),
                            onSelected: (_) => setState(() {
                              _emoji = e;
                              _avatarData = '';
                            }),
                          );
                        }).toList(),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        children: [
                          OutlinedButton.icon(
                            onPressed: _busy ? null : _pickAvatar,
                            icon: const Icon(Icons.image, size: 18),
                            label: const Text('上传图片'),
                          ),
                          if (_avatarData.isNotEmpty)
                            TextButton(
                              onPressed: () =>
                                  setState(() => _avatarData = ''),
                              child: const Text('清除图片'),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _taNameCtl,
              decoration: const InputDecoration(labelText: 'TA 的名字 *'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _genderCtl,
              decoration: const InputDecoration(
                  labelText: '性别（可选）', hintText: '男 / 女 / 其他'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _relCtl,
              decoration: const InputDecoration(
                  labelText: '你和 TA 的关系（可选）', hintText: '比如：死党 / 同学'),
            ),
            const SizedBox(height: 6),
            const Text('API key 在「设置」里统一填，这里不用填。',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 14),
            _buildConsent(),
            const SizedBox(height: 10),
            ElevatedButton(
              onPressed: (_busy || !_consent) ? null : _runDistill,
              child: const Text('开始蒸馏'),
            ),
          ],
        ),
      ),
    );
  }

  // —— 第 3 步 ——

  Widget _buildReview() {
    final p = _persona;
    final r = _result;
    if (p == null || r == null) return const SizedBox.shrink();
    final issues = r.issues;

    Widget item(String key, Map m, String label, String strengthLabel,
        double strength, int nEv) {
      final on = _accept[key] ?? true;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Checkbox(
              value: on,
              activeColor: kWechatGreen,
              onChanged: (v) => setState(() => _accept[key] = v ?? true),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  Text('$strengthLabel ${strength.toStringAsFixed(2)} · 证据 $nEv 条',
                      style: const TextStyle(
                          fontSize: 12, color: Colors.grey)),
                  const SizedBox(height: 2),
                  Text((m['description'] ?? '').toString(),
                      style: const TextStyle(fontSize: 13, height: 1.35)),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('03 · 像不像？',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text('蒸馏出 ${r.traits} 条特质 / ${r.flaws} 条缺点。'
                    '取消勾选不认同的，剩下的直接生效。',
                    style: const TextStyle(fontSize: 13, color: Colors.grey)),
                if (issues.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: Text('⚠️ 校验发现 ${issues.length} 处引用问题',
                        style: const TextStyle(
                            color: kWechatGreen, fontSize: 13)),
                    children: [
                      for (final x in issues)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text('· ${x.toString()}',
                              style: const TextStyle(fontSize: 12)),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        for (var i = 0; i < p.traits.length; i++)
          item('t$i', p.traits[i] as Map, '特质：${(p.traits[i] as Map)['name']}',
              '强度',
              ((p.traits[i] as Map)['weight'] as num? ?? 0).toDouble(),
              ((p.traits[i] as Map)['evidence'] as List? ?? []).length),
        for (var i = 0; i < p.flaws.length; i++)
          item('f$i', p.flaws[i] as Map, '缺点：${(p.flaws[i] as Map)['type']}',
              '烈度',
              ((p.flaws[i] as Map)['intensity'] as num? ?? 0).toDouble(),
              ((p.flaws[i] as Map)['evidence'] as List? ?? []).length),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('缺点强度：${(_flawScale * 100).round()}%',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                Slider(
                  value: _flawScale,
                  min: 0,
                  max: 1,
                  divisions: 20,
                  activeColor: kWechatGreen,
                  label: '${(_flawScale * 100).round()}%',
                  onChanged: (v) => setState(() => _flawScale = v),
                ),
                const Text('调高 = TA 的缺点表现得更频繁、更明显。',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        _detailsTile(p),
        const SizedBox(height: 16),
        ElevatedButton(
          onPressed: _busy ? null : _submitReview,
          child: const Text('完成，开始聊天'),
        ),
      ],
    );
  }

  Widget _detailsTile(Persona p) {
    final raw = p.raw;
    final st = (raw['speech_style'] as Map? ?? {});
    final kb = (raw['knowledge_bounds'] as Map? ?? {});
    final warnings = (raw['warnings'] as List? ?? []);
    String join(dynamic v) =>
        (v as List? ?? []).map((e) => e.toString()).join('、');

    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: const Text('蒸馏明细', style: TextStyle(fontSize: 13)),
      children: [
        _detailRow('语气', (st['tone'] ?? '').toString()),
        _detailRow('句长', (st['sentence_length'] ?? '').toString()),
        _detailRow('口头禅', join(st['catchphrases'])),
        _detailRow('标点习惯', (st['punctuation'] ?? '').toString()),
        _detailRow('表情习惯', (st['emoji_usage'] ?? '').toString()),
        _detailRow('懂的领域', join(kb['confident'])),
        _detailRow('半懂的领域', join(kb['shaky'])),
        _detailRow('不懂的领域', join(kb['clueless'])),
        _detailRow('原话样本', '${(raw['style_samples'] as List? ?? []).length} 组'),
        if (warnings.isNotEmpty)
          _detailRow('模型自标存疑', warnings.map((e) => '· $e').join('\n')),
      ],
    );
  }

  Widget _detailRow(String k, String v) {
    if (v.trim().isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
              width: 92,
              child: Text(k,
                  style: const TextStyle(fontSize: 12, color: Colors.grey))),
          Expanded(
              child: Text(v.trim(),
                  style: const TextStyle(fontSize: 13, height: 1.3))),
        ],
      ),
    );
  }
}

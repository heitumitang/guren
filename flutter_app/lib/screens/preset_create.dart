/// 预设人格创建：勾选性格标签，后端合并 traits/flaws/风格生成完整人格；完成后 pop 返回 npc_id。
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models.dart';
import '../state.dart';
import '../theme.dart';

const _kEmojis = ['🙂', '😊', '😎', '🤔', '🥲', '😴', '😤', '🦊', '🐱', '🐶', '🌙', '☕'];

/// basics 选填字段（键为后端 persona.basics 的键）。
const _kBasicKeys = ['gender', 'age', 'occupation', 'mbti', 'birthday', 'hobbies', 'bio'];
const _kBasicLabels = {
  'gender': '性别',
  'age': '年龄',
  'occupation': '职业',
  'mbti': 'MBTI',
  'birthday': '生日',
  'hobbies': '爱好',
  'bio': '简介',
};

class PresetCreateScreen extends StatefulWidget {
  const PresetCreateScreen({super.key});

  @override
  State<PresetCreateScreen> createState() => _PresetCreateScreenState();
}

class _PresetCreateScreenState extends State<PresetCreateScreen> {
  List<Preset> _presets = [];
  final Set<String> _picked = {};
  final _nameCtl = TextEditingController();
  final _relCtl = TextEditingController();
  final Map<String, TextEditingController> _basicCtls = {};
  String _emoji = '🙂';
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    for (final k in _kBasicKeys) {
      _basicCtls[k] = TextEditingController();
    }
    _load();
  }

  @override
  void dispose() {
    _nameCtl.dispose();
    _relCtl.dispose();
    for (final c in _basicCtls.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final s = context.read<AppState>();
      final r = await s.api.getPresets();
      if (!mounted) return;
      setState(() {
        _presets = r.presets;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _create() async {
    if (_picked.isEmpty) {
      _toast('至少选一个性格');
      return;
    }
    final name = _nameCtl.text.trim();
    if (name.isEmpty) {
      _toast('先填名字');
      return;
    }
    setState(() => _busy = true);
    try {
      final s = context.read<AppState>();
      // 选填 basics：只提交非空字段，避免空串覆盖后端默认
      final basics = <String, dynamic>{
        for (final k in _kBasicKeys) k: _basicCtls[k]!.text.trim()
      }..removeWhere((_, v) => v.isEmpty);
      final r = await s.api.createCharacter(
        name: name,
        tags: _picked.toList(),
        emoji: _emoji,
        basics: basics,
        relation: _relCtl.text.trim(),
      );
      if (!mounted) return;
      Navigator.pop(context, r.id);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _toast('创建失败：$e');
    }
  }

  Widget _card(String title, List<Widget> children) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(
                    fontWeight: FontWeight.w600, color: kWechatGreen)),
            const SizedBox(height: 10),
            ...children,
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('自由组合性格')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('加载失败：$_error',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.grey)),
                      const SizedBox(height: 12),
                      OutlinedButton(
                          onPressed: _load, child: const Text('重试')),
                    ],
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    _card('01 · 选性格（至少一个，可多选融合）', [
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final p in _presets)
                            _PresetChip(
                              preset: p,
                              selected: _picked.contains(p.id),
                              onTap: () => setState(() {
                                if (_picked.contains(p.id)) {
                                  _picked.remove(p.id);
                                } else {
                                  _picked.add(p.id);
                                }
                              }),
                            ),
                        ],
                      ),
                      if (_picked.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          '已选 ${_picked.length} 个：特质/缺点/说话风格将合并成一个人',
                          style: const TextStyle(
                              fontSize: 12, color: kWechatGreen),
                        ),
                      ],
                    ]),
                    const SizedBox(height: 12),
                    _card('02 · TA 是谁', [
                      TextField(
                        controller: _nameCtl,
                        decoration: const InputDecoration(labelText: '名字 *'),
                      ),
                      const SizedBox(height: 8),
                      const Text('头像',
                          style: TextStyle(fontSize: 12, color: Colors.grey)),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 8,
                        children: [
                          for (final e in _kEmojis)
                            GestureDetector(
                              onTap: () =>
                                  setState(() => _emoji = e),
                              child: Container(
                                width: 40,
                                height: 40,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: _emoji == e
                                      ? kWechatGreenSoft.withOpacity(0.35)
                                      : null,
                                  border: Border.all(
                                    color: _emoji == e
                                        ? kWechatGreen
                                        : Theme.of(context).dividerColor,
                                  ),
                                ),
                                child: Text(e,
                                    style: const TextStyle(fontSize: 20)),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _relCtl,
                        decoration: const InputDecoration(
                            labelText: '与你的关系（可选）'),
                      ),
                    ]),
                    const SizedBox(height: 12),
                    _card('03 · 基本信息（选填）', [
                      for (final k in _kBasicKeys) ...[
                        TextField(
                          controller: _basicCtls[k],
                          decoration:
                              InputDecoration(labelText: _kBasicLabels[k]!),
                        ),
                        const SizedBox(height: 4),
                      ],
                    ]),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: _busy ? null : _create,
                      child: _busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('创建'),
                    ),
                  ],
                ),
    );
  }
}

/// 单个性格标签：选中时朱砂描边，名字 + 一句 tagline。
class _PresetChip extends StatelessWidget {
  final Preset preset;
  final bool selected;
  final VoidCallback onTap;

  const _PresetChip({
    required this.preset,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: selected ? kWechatGreenSoft.withOpacity(0.22) : null,
          border: Border.all(
              color: selected ? kWechatGreen : Theme.of(context).dividerColor),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('${preset.emoji} ${preset.name}',
                style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: selected ? kWechatGreen : null)),
            if (preset.desc.isNotEmpty)
              Text(preset.desc,
                  style: const TextStyle(fontSize: 11, color: Colors.grey)),
          ],
        ),
      ),
    );
  }
}

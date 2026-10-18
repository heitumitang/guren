/// 人格详情页：查看/编辑一位 TA 的完整档案（基本信息/关系/行为参数/特质/缺点/报告）。
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import '../models.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets.dart';

/// basics 的可编辑字段（键为后端 persona.basics 的键）。
const _kBasicKeys = ['gender', 'age', 'occupation', 'mbti', 'birthday', 'hobbies', 'bio', 'notes'];
const _kBasicLabels = {
  'gender': '性别',
  'age': '年龄',
  'occupation': '职业',
  'mbti': 'MBTI',
  'birthday': '生日',
  'hobbies': '爱好',
  'bio': '简介',
  'notes': '备注',
};

/// 头像 emoji 候选（与蒸馏向导同风格）。
const _kProfileEmojis = ['🙂', '😊', '😎', '🤔', '🥲', '😴', '😤', '🦊', '🐱', '🐶', '🌙', '☕'];

class PersonaDetailScreen extends StatefulWidget {
  final String npcId;

  const PersonaDetailScreen({super.key, required this.npcId});

  @override
  State<PersonaDetailScreen> createState() => _PersonaDetailScreenState();
}

class _PersonaDetailScreenState extends State<PersonaDetailScreen> {
  Persona? _persona;
  String _report = '';
  bool _loading = true;
  String? _error;
  late double _flawScale;
  late double _replyRate;
  List<Map<String, dynamic>> _rels = [];
  final _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = context.read<AppState>().api;
      final rs = await Future.wait([
        api.getCharacter(widget.npcId),
        api.getReport(widget.npcId),
      ]);
      if (!mounted) return;
      final p = rs[0] as Persona;
      setState(() {
        _persona = p;
        _report = rs[1] as String;
        _flawScale = p.flawScale;
        _replyRate = p.replyRate;
        _rels = p.relations
            .map((r) => Map<String, dynamic>.from(r as Map))
            .toList();
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
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _editBasics() async {
    final p = _persona;
    if (p == null) return;
    final ctls = <String, TextEditingController>{
      for (final k in _kBasicKeys)
        k: TextEditingController(text: (p.basics[k] ?? '').toString()),
    };
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('基本信息'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final k in _kBasicKeys)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: TextField(
                    controller: ctls[k],
                    decoration: InputDecoration(labelText: _kBasicLabels[k]),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('保存')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final updated = await context.read<AppState>().api.updateMeta(
            widget.npcId,
            {'basics': {for (final k in _kBasicKeys) k: ctls[k]!.text.trim()}},
          );
      if (!mounted) return;
      setState(() => _persona = updated);
    } catch (e) {
      _toast('保存失败：$e');
    }
  }

  Future<void> _editRelation() async {
    final p = _persona;
    if (p == null) return;
    final bondCtl = TextEditingController(text: p.relation);
    final callCtl = TextEditingController(text: p.callMe);
    final ctxCtl = TextEditingController(text: p.relContext);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('关系'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
                controller: bondCtl,
                decoration: const InputDecoration(
                    labelText: '你和 TA 的关系', hintText: '比如：死党 / 同学')),
            const SizedBox(height: 8),
            TextField(
                controller: callCtl,
                decoration: const InputDecoration(
                    labelText: 'TA 怎么称呼你', hintText: '比如：老李')),
            const SizedBox(height: 8),
            TextField(
                controller: ctxCtl,
                maxLines: 3,
                decoration: const InputDecoration(
                    labelText: '共同经历 / 背景',
                    alignLabelWithHint: true,
                    hintText: '比如：大学室友，一起在西安实习过')),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('保存')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final updated = await context.read<AppState>().api.updateMeta(
            widget.npcId,
            {
              'relation': bondCtl.text.trim(),
              'call_me': callCtl.text.trim(),
              'rel_context': ctxCtl.text.trim(),
            },
          );
      if (!mounted) return;
      setState(() => _persona = updated);
    } catch (e) {
      _toast('保存失败：$e');
    }
  }

  Future<void> _editProfile() async {
    final p = _persona;
    if (p == null) return;
    final nameCtl = TextEditingController(text: p.name);
    var emoji = p.emoji;
    var imageData = p.avatar;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: const Text('编辑资料'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Avatar(emoji: emoji, imageUrl: imageData, size: 72),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: nameCtl,
                  decoration: const InputDecoration(labelText: 'TA 的名字'),
                ),
                const SizedBox(height: 12),
                const Text('头像 emoji',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: _kProfileEmojis.map((e) {
                    return ChoiceChip(
                      label: Text(e),
                      selected: emoji == e && imageData.isEmpty,
                      selectedColor: kWechatGreenSoft.withOpacity(0.35),
                      onSelected: (_) => setDlg(() {
                        emoji = e;
                        imageData = '';
                      }),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () async {
                        try {
                          final x = await _picker.pickImage(
                              source: ImageSource.gallery);
                          if (x == null) return;
                          final b64 = base64Encode(await x.readAsBytes());
                          setDlg(() =>
                              imageData = 'data:image/png;base64,$b64');
                        } catch (e) {
                          if (ctx.mounted) {
                            ScaffoldMessenger.of(ctx).showSnackBar(
                                SnackBar(content: Text('选图失败：$e')));
                          }
                        }
                      },
                      icon: const Icon(Icons.image, size: 18),
                      label: const Text('上传图片'),
                    ),
                    if (imageData.isNotEmpty)
                      TextButton(
                        onPressed: () => setDlg(() => imageData = ''),
                        child: const Text('清除图片'),
                      ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('保存')),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final updated = await context.read<AppState>().api.updateMeta(
            widget.npcId,
            {
              'name': nameCtl.text.trim(),
              'emoji': emoji,
              'avatar': imageData,
            },
          );
      if (!mounted) return;
      setState(() => _persona = updated);
    } catch (e) {
      _toast('保存失败：$e');
    }
  }

  /// 全量替换 relations（后端会做双向同步：对方档案里自动出现/移除反向关系）。
  Future<void> _saveRelations() async {
    try {
      final updated = await context.read<AppState>().api.updateMeta(
            widget.npcId,
            {'relations': _rels},
          );
      if (!mounted) return;
      setState(() => _persona = updated);
    } catch (e) {
      _toast('保存失败：$e');
    }
  }

  Future<void> _addRelation() async {
    final s = context.read<AppState>();
    if (s.characters.isEmpty) {
      try {
        await s.refreshCharacters();
      } catch (_) {}
      if (!mounted) return;
    }
    final others = s.characters.where((c) => c.id != widget.npcId).toList();
    if (others.isEmpty) {
      _toast('还没有其他 TA，先去创建一位');
      return;
    }
    String? picked = others.first.id;
    final relCtl = TextEditingController();
    final ctxCtl = TextEditingController();
    var share = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: const Text('添加关系'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: picked,
                decoration: const InputDecoration(labelText: '关联哪位 TA'),
                items: others
                    .map((c) => DropdownMenuItem(
                        value: c.id,
                        child: Text('${c.emoji} ${c.name}')))
                    .toList(),
                onChanged: (v) => picked = v,
              ),
              const SizedBox(height: 8),
              TextField(
                controller: relCtl,
                decoration: const InputDecoration(
                    labelText: 'TA 与 TA 的关系', hintText: '比如：同事 / 前任'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: ctxCtl,
                maxLines: 2,
                decoration: const InputDecoration(
                    labelText: '共同经历 / 背景（可选）',
                    alignLabelWithHint: true),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                activeColor: kWechatGreen,
                title: const Text('共享记忆', style: TextStyle(fontSize: 14)),
                subtitle: const Text('聊其中一位时，另一位也知道相关话题',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
                value: share,
                onChanged: (v) => setDlg(() => share = v),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('添加')),
          ],
        ),
      ),
    );
    if (ok != true || !mounted || picked == null) return;
    final target = others.firstWhere((c) => c.id == picked);
    setState(() => _rels.add({
          'npc_id': target.id,
          'name': target.name,
          'relation': relCtl.text.trim(),
          'share_memory': share,
          'context': ctxCtl.text.trim(),
        }));
    await _saveRelations();
  }

  Future<void> _saveScale() async {
    try {
      await context.read<AppState>().api.scale(widget.npcId, _flawScale, _replyRate);
    } catch (e) {
      _toast('保存失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _persona;
    return Scaffold(
      appBar: AppBar(title: Text(p?.name ?? '人格详情')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('加载失败：$_error',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: kWechatGreen)),
                      const SizedBox(height: 12),
                      ElevatedButton(
                          onPressed: _load, child: const Text('重试')),
                    ],
                  ),
                )
              : _buildBody(p!),
    );
  }

  Widget _buildBody(Persona p) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _headerCard(p),
        const SizedBox(height: 12),
        _basicsCard(p),
        const SizedBox(height: 12),
        _relationCard(p),
        const SizedBox(height: 12),
        _behaviorCard(p),
        const SizedBox(height: 12),
        _traitsCard(p),
        const SizedBox(height: 12),
        _flawsCard(p),
        const SizedBox(height: 12),
        _styleCard(p),
        const SizedBox(height: 12),
        _relationsCard(p),
        const SizedBox(height: 12),
        _reportCard(),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _card(String title, {Widget? trailing, required List<Widget> children}) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                    child: Text(title,
                        style: const TextStyle(fontWeight: FontWeight.w600))),
                if (trailing != null) trailing,
              ],
            ),
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _headerCard(Persona p) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Avatar(emoji: p.emoji, imageUrl: p.avatar, size: 64),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(p.name,
                      style: const TextStyle(
                          fontSize: 20, fontWeight: FontWeight.w600)),
                  if (p.relation.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(p.relation,
                        style: const TextStyle(
                            fontSize: 13, color: Colors.grey)),
                  ],
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      _statusChip(p.reviewStatus),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.edit_outlined, size: 18),
                        tooltip: '编辑名字 / 头像',
                        visualDensity: VisualDensity.compact,
                        onPressed: _editProfile,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusChip(String status) {
    final approved = status == 'approved';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: approved
            ? kWechatGreen.withOpacity(0.12)
            : Colors.grey.withOpacity(0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(approved ? '已校准' : '待校准',
          style: TextStyle(
              fontSize: 12,
              color: approved ? kWechatGreen : Colors.grey,
              fontWeight: FontWeight.w600)),
    );
  }

  Widget _reviewBadge(String review) {
    final color = switch (review) {
      'accepted' => kWechatGreen,
      'rejected' => Colors.grey,
      _ => Colors.orange,
    };
    final label = switch (review) {
      'accepted' => '已采纳',
      'rejected' => '已否决',
      _ => '待定',
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(label,
          style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600)),
    );
  }

  Widget _basicsCard(Persona p) {
    return _card(
      '01 · 基本信息',
      trailing: TextButton(onPressed: _editBasics, child: const Text('编辑')),
      children: [
        for (final k in _kBasicKeys)
          _kvRow(_kBasicLabels[k]!, (p.basics[k] ?? '').toString()),
      ],
    );
  }

  Widget _relationCard(Persona p) {
    return _card(
      '02 · 关系',
      trailing: TextButton(onPressed: _editRelation, child: const Text('编辑')),
      children: [
        _kvRow('TA 怎么称呼你', p.callMe),
        _kvRow('共同经历 / 背景', p.relContext),
      ],
    );
  }

  Widget _behaviorCard(Persona p) {
    return _card('03 · 行为参数', children: [
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
        onChangeEnd: (_) => _saveScale(),
      ),
      Text('回复率：${(_replyRate * 100).round()}%',
          style: const TextStyle(fontWeight: FontWeight.w600)),
      Slider(
        value: _replyRate,
        min: 0,
        max: 1,
        divisions: 20,
        activeColor: kWechatGreen,
        label: '${(_replyRate * 100).round()}%',
        onChanged: (v) => setState(() => _replyRate = v),
        onChangeEnd: (_) => _saveScale(),
      ),
      const Text('调低回复率 = TA 会「已读不回」。松手即自动保存。',
          style: TextStyle(fontSize: 12, color: Colors.grey)),
    ]);
  }

  Widget _traitsCard(Persona p) {
    if (p.traits.isEmpty) {
      return _card('04 · 性格特质',
          children: const [Text('暂无特质', style: TextStyle(color: Colors.grey))]);
    }
    return _card('04 · 性格特质（${p.traits.length}）', children: [
      for (final t in p.traits)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                      child: Text((t as Map)['name'] ?? '',
                          style: const TextStyle(fontWeight: FontWeight.w600))),
                  _reviewBadge((t['review'] ?? '').toString()),
                ],
              ),
              Text(
                  '强度 ${((t['weight'] as num?) ?? 0).toStringAsFixed(2)}'
                  ' · 置信 ${((t['confidence'] as num?) ?? 0).toStringAsFixed(2)}'
                  ' · 证据 ${(t['evidence'] as List? ?? []).length} 条',
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
              Text((t['description'] ?? '').toString(),
                  style: const TextStyle(fontSize: 13, height: 1.35)),
            ],
          ),
        ),
    ]);
  }

  Widget _flawsCard(Persona p) {
    if (p.flaws.isEmpty) {
      return _card('05 · 缺点',
          children: const [Text('暂无缺点', style: TextStyle(color: Colors.grey))]);
    }
    return _card('05 · 缺点（${p.flaws.length}）', children: [
      for (final f in p.flaws)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                      child: Text((f as Map)['type'] ?? '',
                          style: const TextStyle(fontWeight: FontWeight.w600))),
                  _reviewBadge((f['review'] ?? '').toString()),
                ],
              ),
              Text(
                  '烈度 ${((f['intensity'] as num?) ?? 0).toStringAsFixed(2)}'
                  ' · 证据 ${(f['evidence'] as List? ?? []).length} 条',
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
              Text((f['description'] ?? '').toString(),
                  style: const TextStyle(fontSize: 13, height: 1.35)),
            ],
          ),
        ),
    ]);
  }

  Widget _styleCard(Persona p) {
    final raw = p.raw;
    final st = (raw['speech_style'] as Map? ?? {});
    final kb = (raw['knowledge_bounds'] as Map? ?? {});
    final warnings = (raw['warnings'] as List? ?? []);
    String join(dynamic v) =>
        (v as List? ?? []).map((e) => e.toString()).join('、');

    return Card(
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 14),
        title: const Text('06 · 说话风格', style: TextStyle(fontSize: 14)),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _kvRow('语气', (st['tone'] ?? '').toString()),
                _kvRow('句长', (st['sentence_length'] ?? '').toString()),
                _kvRow('口头禅', join(st['catchphrases'])),
                _kvRow('标点习惯', (st['punctuation'] ?? '').toString()),
                _kvRow('表情习惯', (st['emoji_usage'] ?? '').toString()),
                _kvRow('懂的领域', join(kb['confident'])),
                _kvRow('半懂的领域', join(kb['shaky'])),
                _kvRow('不懂的领域', join(kb['clueless'])),
                _kvRow('原话样本', '${(raw['style_samples'] as List? ?? []).length} 组'),
                if (warnings.isNotEmpty)
                  _kvRow('模型自标存疑', warnings.map((e) => '· $e').join('\n')),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _relationsCard(Persona p) {
    return _card(
      '07 · 关系网（${_rels.length}）',
      trailing: TextButton.icon(
        onPressed: _addRelation,
        icon: const Icon(Icons.add, size: 18),
        label: const Text('添加'),
      ),
      children: [
        if (_rels.isEmpty)
          const Text('还没设置。添加后，就能跟这个 TA 聊起 TA 认识的人了。',
              style: TextStyle(color: Colors.grey, fontSize: 13))
        else
          for (var i = 0; i < _rels.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('👤 ${_rels[i]['name'] ?? ''}',
                            style:
                                const TextStyle(fontWeight: FontWeight.w600)),
                        Text(
                            [
                              (_rels[i]['relation'] ?? '').toString(),
                              (_rels[i]['context'] ?? '').toString(),
                            ].where((s) => s.isNotEmpty).join(' · '),
                            style: const TextStyle(
                                fontSize: 12, color: Colors.grey)),
                      ],
                    ),
                  ),
                    Tooltip(
                    message: '共享记忆',
                    child: Switch(
                      value: (_rels[i]['share_memory'] as bool?) ?? false,
                      activeThumbColor: kWechatGreen,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      onChanged: (v) {
                        setState(() => _rels[i]['share_memory'] = v);
                        _saveRelations();
                      },
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    tooltip: '移除关系',
                    visualDensity: VisualDensity.compact,
                    onPressed: () {
                      final removed = _rels[i]['name'] ?? '';
                      setState(() => _rels.removeAt(i));
                      _saveRelations();
                      _toast('已移除与「$removed」的关系（对方档案同步更新）');
                    },
                  ),
                ],
              ),
            ),
        const SizedBox(height: 4),
        const Text('改动自动保存；共享记忆 = 聊其中一位时，另一位也知道相关话题。',
            style: TextStyle(fontSize: 12, color: Colors.grey)),
      ],
    );
  }

  Widget _reportCard() {
    return _card('08 · 蒸馏报告', children: [
      if (_report.isEmpty)
        const Text('这位 TA 没有蒸馏报告（手动创建，或报告尚未生成）。',
            style: TextStyle(color: Colors.grey, fontSize: 13))
      else
        Container(
          constraints: const BoxConstraints(maxHeight: 360),
          child: SingleChildScrollView(
            child: SelectableText(_report,
                style: const TextStyle(fontSize: 13, height: 1.5)),
          ),
        ),
    ]);
  }

  Widget _kvRow(String k, String v) {
    if (v.trim().isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
              width: 110,
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

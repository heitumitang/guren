/// 人物列表：展示已蒸馏的 TA，支持创建 / 进入 / 删除。
///
/// 响应式布局（微信式）：
/// - 桌面（宽度 >= 720）：左栏聊天列表 + 右栏聊天页，同屏双栏。
/// - 手机：单栏，点列表项 push 进聊天页。
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets.dart';
import 'chat.dart';
import 'distill.dart';
import 'persona_detail.dart';
import 'preset_create.dart';
import 'settings.dart';

class CharacterListScreen extends StatefulWidget {
  const CharacterListScreen({super.key});

  @override
  State<CharacterListScreen> createState() => _CharacterListScreenState();
}

class _CharacterListScreenState extends State<CharacterListScreen> {
  bool _loading = false;
  String? _selectedId; // 桌面端当前选中的聊天
  Timer? _unreadTimer;

  @override
  void initState() {
    super.initState();
    _refresh();
    // 周期静默刷新未读（本地后端，很轻）
    _unreadTimer = Timer.periodic(
      const Duration(seconds: 6),
      (_) => _refreshSilent(),
    );
  }

  @override
  void dispose() {
    _unreadTimer?.cancel();
    super.dispose();
  }

  bool _isDesktop(BuildContext c) => MediaQuery.of(c).size.width >= 720;

  Future<void> _refresh() async {
    setState(() => _loading = true);
    final s = context.read<AppState>();
    try {
      await s.refreshCharacters();
    } on Exception catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('刷新失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 不带 loading 指示的刷新，供未读轮询用，避免列表闪动。
  Future<void> _refreshSilent() async {
    final s = context.read<AppState>();
    try {
      await s.refreshCharacters();
    } on Exception {
      // 静默
    }
  }

  void _open(CharacterIndex c) {
    if (_isDesktop(context)) {
      setState(() => _selectedId = c.id);
      // 稍后刷新，让 ChatScreen 里的 markRead 先落库，清掉该 NPC 未读
      Future.delayed(const Duration(seconds: 1), () {
        if (mounted) _refreshSilent();
      });
    } else {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ChatScreen(npcId: c.id, name: c.name, emoji: c.emoji),
        ),
      ).then((_) => _refresh());
    }
  }

  /// 蒸馏向导完成后按 id 打开刚创建的人物。
  Future<void> _openById(String id) async {
    await _refresh();
    if (!mounted) return;
    final s = context.read<AppState>();
    CharacterIndex? found;
    for (final x in s.characters) {
      if (x.id == id) {
        found = x;
        break;
      }
    }
    if (found != null) {
      _open(found);
    } else {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已创建，刷新列表即可看到')));
    }
  }

  void _showCreateChooser() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Text('📷', style: TextStyle(fontSize: 24)),
              title: const Text('从聊天记录蒸馏'),
              subtitle: const Text('导入微信/QQ 记录，蒸出真实的 TA'),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const DistillWizard()),
                ).then((id) {
                  if (id is String && id.isNotEmpty) _openById(id);
                });
              },
            ),
            ListTile(
              leading: const Text('🎭', style: TextStyle(fontSize: 24)),
              title: const Text('自由组合性格'),
              subtitle: const Text('勾选几种性格特质，融合成一个全新的 TA'),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const PresetCreateScreen()),
                ).then((id) {
                  if (id is String && id.isNotEmpty) _openById(id);
                });
              },
            ),
            ListTile(
              leading: const Text('✨', style: TextStyle(fontSize: 24)),
              title: const Text('手动创建'),
              subtitle: const Text('起个名字，直接开聊'),
              onTap: () {
                Navigator.pop(ctx);
                _createManual();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _createManual() async {
    final nameCtl = TextEditingController();
    final emojiCtl = TextEditingController(text: '🙂');
    final relCtl = TextEditingController();
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建一位 TA'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: emojiCtl,
              decoration: const InputDecoration(labelText: '头像 emoji'),
            ),
            TextField(
              controller: nameCtl,
              decoration: const InputDecoration(labelText: 'TA 的名字'),
            ),
            TextField(
              controller: relCtl,
              decoration: const InputDecoration(labelText: '与你的关系（可选）'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (result != true) return;
    if (!mounted) return;
    final s = context.read<AppState>();
    try {
      await s.api.createCharacter(
        name: nameCtl.text.trim().isEmpty ? '未命名' : nameCtl.text.trim(),
        emoji: emojiCtl.text.trim(),
        relation: relCtl.text.trim(),
      );
      await _refresh();
    } on Exception catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('创建失败：$e')));
      }
    }
  }

  Future<void> _delete(CharacterIndex c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这位 TA？'),
        content: Text('将移除「${c.name}」的索引与数据（软删除）。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: kCinnabar)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!mounted) return;
    final s = context.read<AppState>();
    try {
      await s.api.deleteCharacter(c.id);
      if (_selectedId == c.id) setState(() => _selectedId = null);
      await _refresh();
    } on Exception catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('删除失败：$e')));
      }
    }
  }

  // ---------- 列表主体 ----------

  Widget _buildList(AppState s) {
    if (s.characters.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('还没有 TA。点右下角「+」，从聊天记录蒸馏一位，或手动创建。',
              textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: s.characters.length,
      separatorBuilder: (_, __) => const Divider(height: 1, indent: 88),
      itemBuilder: (_, i) {
        final c = s.characters[i];
        return ListTile(
          leading: Stack(
            clipBehavior: Clip.none,
            children: [
              Avatar(emoji: c.emoji, imageUrl: c.avatar, size: 56),
              if (c.unread > 0)
                Positioned(
                  right: -4,
                  top: -4,
                  child: _UnreadBadge(c.unread),
                ),
            ],
          ),
          title: Text(
            c.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            c.relation.isNotEmpty ? c.relation : '轻触开始聊天',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              color: c.relation.isNotEmpty
                  ? Colors.grey
                  : Theme.of(context)
                      .colorScheme
                      .primary
                      .withValues(alpha: 0.55),
            ),
          ),
          trailing: IconButton(
            icon: const Icon(Icons.info_outline, size: 20),
            tooltip: '人格详情',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => PersonaDetailScreen(npcId: c.id),
              ),
            ).then((_) => _refresh()),
          ),
          selected: _selectedId == c.id,
          onTap: () => _open(c),
          onLongPress: () => _delete(c),
        );
      },
    );
  }

  // ---------- 桌面双栏 ----------

  Widget _desktopHeader() {
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
        child: Row(
          children: [
            const Text('故人',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.add),
              tooltip: '新建 TA',
              onPressed: _showCreateChooser,
            ),
            IconButton(
              icon: _loading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
              tooltip: '刷新',
              onPressed: _refresh,
            ),
            IconButton(
              icon: const Icon(Icons.settings),
              tooltip: '设置',
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              ).then((_) => _refresh()),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSelectedChat() {
    final s = context.read<AppState>();
    CharacterIndex? c;
    for (final x in s.characters) {
      if (x.id == _selectedId) {
        c = x;
        break;
      }
    }
    if (c == null) return const _EmptyChatPane();
    return ChatScreen(
      key: ValueKey(c.id),
      npcId: c.id,
      name: c.name,
      emoji: c.emoji,
      showNotice: false, // 声明条在左栏统一显示，右栏不重复
    );
  }

  Widget _buildDesktop(AppState s) {
    return Scaffold(
      body: Row(
        children: [
          SizedBox(
            width: 340,
            child: Column(
              children: [
                _desktopHeader(),
                const AiNoticeBar(),
                const Divider(height: 1),
                Expanded(child: _buildList(s)),
              ],
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: _selectedId == null ? const _EmptyChatPane() : _buildSelectedChat(),
          ),
        ],
      ),
    );
  }

  // ---------- 手机单栏 ----------

  Widget _buildMobile(AppState s) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('故人'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
          IconButton(
            icon: _loading
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
        ],
      ),
      body: Column(
        children: [
          const AiNoticeBar(),
          Expanded(child: _buildList(s)),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showCreateChooser,
        tooltip: '新建 TA',
        child: const Icon(Icons.add),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    return _isDesktop(context) ? _buildDesktop(s) : _buildMobile(s);
  }
}

/// 未读红点角标（微信式，数字超过 99 显示 99+）。
class _UnreadBadge extends StatelessWidget {
  final int count;
  const _UnreadBadge(this.count);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
      decoration: BoxDecoration(
        color: kCinnabar,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: Theme.of(context).scaffoldBackgroundColor, width: 1.5),
      ),
      child: Text(
        count > 99 ? '99+' : '$count',
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          height: 1.2,
        ),
      ),
    );
  }
}

/// 桌面右栏空态：还没选中任何一位。
class _EmptyChatPane extends StatelessWidget {
  const _EmptyChatPane();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.chat_bubble_outline, size: 56, color: Colors.grey),
          const SizedBox(height: 12),
          Text('选择一位 TA 开始聊天',
              style: TextStyle(color: Colors.grey.shade500, fontSize: 15)),
        ],
      ),
    );
  }
}

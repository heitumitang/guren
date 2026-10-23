/// 聊天页：加载历史、发送（引用/立即模式）、轮询收件箱收延迟回复、主动发起与时间表预览。
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets.dart';

class ChatScreen extends StatefulWidget {
  final String npcId;
  final String name;
  final String emoji;
  final bool showNotice; // 桌面双栏时由左栏统一显示，右栏不重复

  const ChatScreen({
    super.key,
    required this.npcId,
    required this.name,
    this.emoji = '🙂',
    this.showNotice = true,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _ctl = TextEditingController();
  final _scrollCtl = ScrollController();
  final List<ChatMessage> _msgs = [];
  final Set<String> _seen = {};
  Quote? _quote;
  bool _immediate = false;
  bool _pending = false;
  Timer? _poll;
  bool _busy = false;
  bool _proactiveBusy = false;

  @override
  void initState() {
    super.initState();
    _loadImmediate();
    _load();
    _startPoll(); // 连续轮询：主动消息实时显示 + 持续标已读
  }

  /// 读取「立即模式」开关的持久化状态（每个角色独立）。
  Future<void> _loadImmediate() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _immediate = p.getBool('immediateMode_${widget.npcId}') ?? false);
  }

  /// 切换「立即模式」并持久化（每个角色独立）。
  Future<void> _toggleImmediate() async {
    setState(() => _immediate = !_immediate);
    final p = await SharedPreferences.getInstance();
    await p.setBool('immediateMode_${widget.npcId}', _immediate);
  }

  @override
  void dispose() {
    _poll?.cancel();
    _ctl.dispose();
    _scrollCtl.dispose();
    super.dispose();
  }

  /// 滚到最新一条（等当前帧布局完再滚，hasClients 兜底）。
  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollCtl.hasClients) return;
      _scrollCtl.animateTo(
        _scrollCtl.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  /// 显示不堆叠的提示：先清掉当前+排队的，再显示这一条。
  void _showSnack(String msg) {
    if (!mounted) return;
    final m = ScaffoldMessenger.of(context);
    m.clearSnackBars();
    m.showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 标记已读（清未读红点）。失败静默，不影响主流程。
  void _markRead() {
    context.read<AppState>().api.markRead(widget.npcId).catchError((_) {});
  }

  Future<void> _load() async {
    final s = context.read<AppState>();
    try {
      final hist = await s.api.history(widget.npcId);
      for (final m in hist) {
        _msgs.add(m);
        _seen.add(m.key);
      }
    } on Exception catch (e) {
      if (mounted) {
        _showSnack('载入失败：$e');
      }
    }
    if (mounted) {
      setState(() {});
      _scrollToBottom();
      _markRead();
    }
  }

  /// 把最后一条用户消息标为「已读」（对方已读不回时调用）。
  void _markLastUserRead() {
    for (int i = _msgs.length - 1; i >= 0; i--) {
      if (_msgs[i].role == 'user') {
        _msgs[i] = ChatMessage(
          role: 'user',
          content: _msgs[i].content,
          at: _msgs[i].at,
          read: true,
        );
        break;
      }
    }
    setState(() {});
  }

  void _addUser(String text) {
    final m = ChatMessage(
        role: 'user', content: text, at: DateTime.now());
    _msgs.add(m);
    _seen.add(m.key);
    setState(() {});
    _scrollToBottom();
  }

  void _addAssistant(String text, String atIso) {
    final m = ChatMessage(
        role: 'assistant',
        content: text,
        at: DateTime.tryParse(atIso) ?? DateTime.now());
    _msgs.add(m);
    _seen.add(m.key);
    setState(() {});
    _scrollToBottom();
    _markRead();
  }

  /// 连续轮询收件箱：主动消息实时显示 + 每次轮询标已读（清掉未读红点）。
  void _startPoll() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => _pollOnce());
  }

  Future<void> _pollOnce() async {
    if (!mounted) {
      _poll?.cancel();
      return;
    }
    final s = context.read<AppState>();
    try {
      final items = await s.api.outbox(widget.npcId);
      var gotNew = false;
      for (final it in items) {
        final key = dedupeKey(it.at, it.text);
        if (_seen.contains(key)) continue;
        _seen.add(key);
        if (it.text.isNotEmpty && !it.blocked) {
          _addAssistant(it.text, it.at);
          gotNew = true;
        }
      }
      if (gotNew && _pending) {
        _pending = false;
        if (mounted) setState(() {});
      }
    } on Exception {
      // 轮询失败静默重试
    }
    // 用户正停留在这个聊天页，持续标已读，避免角色主动找来的消息亮红点
    _markRead();
  }

  Future<void> _send() async {
    final text = _ctl.text.trim();
    if (text.isEmpty || _busy) return;
    final s = context.read<AppState>();
    // 组装最近 12 条历史（不含当前这条），让模型记得之前聊过什么
    var hist = [
      for (final m in _msgs)
        if (m.content.trim().isNotEmpty) {'role': m.role, 'content': m.content},
    ];
    if (hist.length > 12) hist = hist.sublist(hist.length - 12);
    _addUser(text);
    final quote = _quote;
    _ctl.clear();
    setState(() => _quote = null);

    _busy = true;
    setState(() {});
    try {
      final r = await s.api.chat(
        widget.npcId,
        message: text,
        history: hist,
        quote: quote,
        llm: s.llm,
        immediate: _immediate,
      );
      if (r.text != null) {
        _addAssistant(r.text!, DateTime.now().toIso8601String());
      } else if (r.replyAt != null) {
        _pending = true;
        if (mounted) setState(() {});
      } else if (!r.willReply) {
        _markLastUserRead();
        _showSnack('TA 已读不回：${r.reason ?? ''}');
      }
    } on Exception catch (e) {
      if (mounted) {
        _showSnack('发送失败：$e');
      }
    } finally {
      _busy = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _proactive() async {
    if (_proactiveBusy) return; // 防连点：在飞就忽略
    setState(() => _proactiveBusy = true);
    final s = context.read<AppState>();
    try {
      final r = await s.api.proactive(widget.npcId, s.llm);
      if (r.initiated && r.text != null) {
        _addAssistant(r.text!, DateTime.now().toIso8601String());
      } else if (r.blocked == true) {
        _showSnack('被红线拦截：${r.reason ?? ''}');
      } else {
        _showSnack('TA 现在不想主动找你');
      }
    } on Exception catch (e) {
      _showSnack('主动发起失败：$e');
    } finally {
      if (mounted) setState(() => _proactiveBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Avatar(emoji: widget.emoji, size: 32),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                widget.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: _proactiveBusy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.bolt),
            tooltip: '让 TA 主动说一句',
            onPressed: _proactiveBusy ? null : _proactive,
          ),
        ],
      ),
      body: Column(
        children: [
          if (widget.showNotice) const AiNoticeBar(),
          Expanded(
            child: _msgs.isEmpty
                ? const Center(
                    child: Text('和 TA 说第一句话吧',
                        style: TextStyle(color: Colors.grey)),
                  )
                : ListView.builder(
                    controller: _scrollCtl,
                    padding: const EdgeInsets.all(12),
                    reverse: false,
                    itemCount: _msgs.length,
                    itemBuilder: (_, i) {
                      final m = _msgs[i];
                      final isLast = i == _msgs.length - 1;
                      final pending = isLast && m.role == 'user' && !m.read;
                      return MessageBubble(
                        msg: m,
                        pending: pending,
                        onLongPress: () {
                          setState(() => _quote = Quote(
                                role: _msgs[i].role,
                                text: _msgs[i].content,
                              ));
                        },
                      );
                    },
                  ),
          ),
          if (_busy || _pending)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: _busy
                    ? const [
                        TypingIndicator(),
                        SizedBox(width: 8),
                        Text('对方正在输入…', style: TextStyle(color: Colors.grey)),
                      ]
                    : const [
                        SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        SizedBox(width: 8),
                        Text('TA 正在考虑怎么回…', style: TextStyle(color: Colors.grey)),
                      ],
              ),
            ),
          if (_quote != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              color: theme.dividerColor.withOpacity(0.2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '引用 ${_quote!.role == 'user' ? '我' : widget.name}：'
                      '${_quote!.text}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 16),
                    onPressed: () => setState(() => _quote = null),
                  ),
                ],
              ),
            ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Row(
                children: [
                  IconButton(
                    icon: Icon(_immediate ? Icons.flash_on : Icons.flash_off,
                        color: _immediate ? kWechatGreen : null),
                    tooltip: '立即模式（关闭时间拟人延迟）',
                    onPressed: _toggleImmediate,
                  ),
                  Expanded(
                    child: TextField(
                      controller: _ctl,
                      decoration: const InputDecoration(
                        hintText: '说点什么…',
                        border: InputBorder.none,
                      ),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  IconButton(
                    icon: _busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send),
                    onPressed: _send,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

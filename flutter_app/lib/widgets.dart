/// 通用小组件：头像、消息气泡、AI 声明条。
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'models.dart';
import 'theme.dart';

/// 头像：优先用图片（data URL / http），否则用 emoji。
class Avatar extends StatelessWidget {
  final String emoji;
  final String imageUrl;
  final double size;

  const Avatar({
    super.key,
    required this.emoji,
    this.imageUrl = '',
    this.size = 44,
  });

  @override
  Widget build(BuildContext context) {
    ImageProvider? img;
    if (imageUrl.startsWith('data:')) {
      final comma = imageUrl.indexOf(',');
      if (comma != -1) {
        try {
          img = MemoryImage(base64Decode(imageUrl.substring(comma + 1)));
        } catch (_) {}
      }
    } else if (imageUrl.startsWith('http')) {
      img = NetworkImage(imageUrl);
    }

    if (img != null) {
      return CircleAvatar(radius: size / 2, backgroundImage: img);
    }
    return CircleAvatar(
      radius: size / 2,
      backgroundColor: kWechatGreenSoft.withOpacity(0.25),
      child: Text(emoji.isNotEmpty ? emoji : '🙂',
          style: TextStyle(fontSize: size * 0.5)),
    );
  }
}

/// 聊天气泡。
class MessageBubble extends StatelessWidget {
  final ChatMessage msg;
  final VoidCallback? onLongPress;
  final bool pending; // 待回复（客户端推断：最后一条用户消息且未读）

  const MessageBubble({super.key, required this.msg, this.onLongPress, this.pending = false});

  @override
  Widget build(BuildContext context) {
    final mine = msg.role == 'user';
    final theme = Theme.of(context);
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onLongPress: onLongPress,
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 4),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              constraints: const BoxConstraints(maxWidth: 280),
              decoration: BoxDecoration(
                color: mine ? kWechatGreenSoft : theme.colorScheme.surface,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16),
                  topRight: const Radius.circular(16),
                  bottomLeft: Radius.circular(mine ? 16 : 4),
                  bottomRight: Radius.circular(mine ? 4 : 16),
                ),
                border: mine
                    ? null
                    : Border.all(color: theme.dividerColor),
              ),
              child: Text(
                msg.content,
                style: TextStyle(
                  color: mine ? Colors.black87 : theme.colorScheme.onSurface,
                  fontSize: 15,
                  height: 1.4,
                ),
              ),
            ),
          ),
          // 状态行：已读 / 待回复（仅用户消息）
          if (mine && (msg.read || pending))
            Padding(
              padding: const EdgeInsets.only(bottom: 2, right: 4),
              child: Text(
                msg.read ? '已读' : '待回复',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
              ),
            ),
        ],
      ),
    );
  }
}

/// 「对方正在输入…」指示器：三个跳动的圆点（微信式）。
class TypingIndicator extends StatefulWidget {
  const TypingIndicator({super.key});

  @override
  State<TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<TypingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            final phase = ((_ctrl.value - i * 0.25) % 1.0 + 1.0) % 1.0;
            final o = 0.25 + 0.75 * (1.0 - phase);
            return Container(
              margin: EdgeInsets.only(right: i < 2 ? 4 : 0),
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: Colors.grey.withValues(alpha: o),
                shape: BoxShape.circle,
              ),
            );
          }),
        );
      },
    );
  }
}

/// AI 生成内容声明条（合规要求显著标识），折叠态持久化于 aiNoticeOpen，默认展开。
class AiNoticeBar extends StatefulWidget {
  const AiNoticeBar({super.key});

  @override
  State<AiNoticeBar> createState() => _AiNoticeBarState();
}

class _AiNoticeBarState extends State<AiNoticeBar> {
  bool _open = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _open = p.getBool('aiNoticeOpen') ?? true);
  }

  Future<void> _toggle() async {
    final v = !_open;
    setState(() => _open = v);
    final p = await SharedPreferences.getInstance();
    await p.setBool('aiNoticeOpen', v);
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    // 琥珀色警示系（与品牌朱砂区分，避免误读成报错）
    final bg = dark ? const Color(0xFF38301E) : const Color(0xFFF6EBD6);
    final ink = dark ? const Color(0xFFE3D3A6) : const Color(0xFF6E5A1E);
    final badgeText = dark ? const Color(0xFF1B1916) : kPaper;

    return Container(
      width: double.infinity,
      color: bg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: _toggle,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              child: Row(
                children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                    decoration: BoxDecoration(
                      color: ink,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text('AI',
                        style: TextStyle(
                            color: badgeText,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.4)),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('所有回复由模型生成，不是真人',
                        style: TextStyle(
                            color: ink,
                            fontSize: 13,
                            fontWeight: FontWeight.w500)),
                  ),
                  Icon(_open ? Icons.expand_less : Icons.expand_more,
                      size: 18, color: ink),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutQuart,
            child: _open
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                    child: Text(
                      '须获得本人同意后使用其聊天记录，不得用于冒充他人或误导第三方。'
                      '本页所有内容均为 AI 生成。',
                      style: TextStyle(color: ink, fontSize: 12, height: 1.6),
                    ),
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}

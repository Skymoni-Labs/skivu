import 'dart:convert';
import 'package:flutter/material.dart';
import 'appearance.dart';
import 'chat_bubble_surface.dart';
import 'native_social_icons.dart';
import 'native_social_local_options.dart';
import 'state.dart';
import 'ui_plugins.dart';

/// Dimensions and ordering follow the shipped 0.2.34 social CSS/JS.
class SocialChatTool {
  const SocialChatTool(
    this.action,
    this.label,
    this.icon, {
    this.disabled = false,
  });
  final String action, label, icon;
  final bool disabled;
}

const wxChatToolPages = [
  [
    SocialChatTool('album', '相册', 'image'),
    SocialChatTool('camera', '拍摄', 'camera'),
    SocialChatTool('video', '视频通话', 'video', disabled: true),
    SocialChatTool('location', '位置', 'pin'),
    SocialChatTool('redpacket-menu', '红包', 'envelope'),
    SocialChatTool('gift', '礼物', 'gift'),
    SocialChatTool('transfer', '转账', 'transfer'),
    SocialChatTool('speech', '语音输入', 'mic'),
  ],
  [
    SocialChatTool('favorites', '收藏', 'box'),
    SocialChatTool('contact', '个人名片', 'user'),
    SocialChatTool('file', '文件', 'folder'),
    SocialChatTool('music', '音乐', 'music'),
    SocialChatTool('describe-image', '描述照片', 'image'),
  ],
];
const qqChatToolPages = [
  [
    SocialChatTool('call', '语音通话', 'phone'),
    SocialChatTool('video', '视频通话', 'video', disabled: true),
    SocialChatTool('location', '位置', 'pin'),
    SocialChatTool('file', '文件', 'folder'),
    SocialChatTool('redpacket', '红包', 'gift'),
    SocialChatTool('transfer', '转账', 'wallet'),
    SocialChatTool('favorites', '收藏', 'star'),
    SocialChatTool('screen', '屏幕分享', 'panel'),
  ],
  [
    SocialChatTool('contact', '名片', 'user'),
    SocialChatTool('gift', '礼物', 'gift'),
    SocialChatTool('music', '一起听歌', 'music'),
    SocialChatTool('describe-image', '描述照片', 'image'),
  ],
];

class SocialChatSurface extends StatelessWidget {
  const SocialChatSurface({
    super.key,
    required this.mode,
    required this.user,
    required this.custom,
    required this.child,
  });
  final ChatUiMode mode;
  final bool user, custom;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    if (custom) return ChatBubbleSurface(user: user, child: child);
    final qq = mode == ChatUiMode.qq;
    return Container(
      key: ValueKey('social-native-surface-${user ? 'user' : 'assistant'}'),
      constraints: const BoxConstraints(minHeight: 40),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: user ? Color(qq ? 0xff009dff : 0xff95ec69) : Colors.white,
        borderRadius: BorderRadius.circular(qq ? 9 : 4),
      ),
      child: DefaultTextStyle.merge(
        style: TextStyle(
          fontSize: nativeSocialLocalOptions.fontSize.toDouble(),
          height: 1.5,
          color: user && qq ? Colors.white : const Color(0xff17191c),
          fontFamily: appearance.fontFamily(
            user ? 'userFont' : 'assistantFont',
          ),
        ),
        child: child,
      ),
    );
  }
}

class SocialChatInlinePanel extends StatefulWidget {
  const SocialChatInlinePanel({
    super.key,
    required this.mode,
    required this.kind,
    required this.store,
    required this.onAction,
    required this.onEmoji,
    required this.onSticker,
    required this.onManage,
  });
  final ChatUiMode mode;
  final String kind;
  final DemoStore store;
  final ValueChanged<String> onAction, onEmoji, onSticker;
  final VoidCallback onManage;
  @override
  State<SocialChatInlinePanel> createState() => _SocialChatInlinePanelState();
}

class _SocialChatInlinePanelState extends State<SocialChatInlinePanel> {
  final _pages = PageController();
  int _page = 0;
  String _group = '';
  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final qq = widget.mode == ChatUiMode.qq;
    final pages = qq ? qqChatToolPages : wxChatToolPages;
    if (widget.kind == 'emoji') {
      final emojis = [
        '😀',
        '😊',
        '🥰',
        '🤔',
        '😂',
        '🥺',
        '😎',
        '😴',
        '👍',
        '👏',
        '❤️',
        '🌹',
        '🎉',
        '✨',
        '☀️',
        '☕',
        if (!qq) ...['😭', '🤝', '💪', '🙏', '🎂', '🎁', '🌙', '🍀'],
      ];
      final stickers = widget.store.stickers
          .where((s) => s.active && (_group.isEmpty || s.groupId == _group))
          .toList();
      return SizedBox(
        key: const ValueKey('social-inline-emoji'),
        height: 300,
        child: SingleChildScrollView(
          child: Column(
            children: [
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                padding: EdgeInsets.only(
                  top: qq ? 12 : 8,
                  bottom: qq ? 12 : 20,
                ),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 8,
                  mainAxisExtent: 43,
                  crossAxisSpacing: 5,
                ),
                itemCount: emojis.length,
                itemBuilder: (_, index) => TextButton(
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    minimumSize: Size.zero,
                  ),
                  onPressed: () => widget.onEmoji(emojis[index]),
                  child: Text(
                    emojis[index],
                    style: const TextStyle(fontSize: 24),
                  ),
                ),
              ),
              const Divider(height: 1),
              SizedBox(
                height: 50,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  children: [
                    for (final group in <(String, String)>[
                      ('', '全部'),
                      for (final g in widget.store.stickerGroups)
                        (g.id, g.name),
                    ])
                      Padding(
                        padding: const EdgeInsets.only(right: 7),
                        child: TextButton(
                          style: TextButton.styleFrom(
                            backgroundColor: _group == group.$1
                                ? Color(qq ? 0xffd8edfa : 0xffd9eade)
                                : Colors.white54,
                            foregroundColor: _group == group.$1
                                ? Color(qq ? 0xff2275a1 : 0xff226d42)
                                : const Color(0xff5c646a),
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            textStyle: const TextStyle(fontSize: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(5),
                            ),
                          ),
                          onPressed: () => setState(() => _group = group.$1),
                          child: Text(group.$2),
                        ),
                      ),
                    TextButton(
                      onPressed: widget.onManage,
                      child: const Text('＋ 管理', style: TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
              ),
              if (stickers.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text(
                    '添加自己的表情，并按分组整理。',
                    style: TextStyle(fontSize: 12, color: Color(0xff888888)),
                  ),
                ),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.only(bottom: 10),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 4,
                  mainAxisExtent: 89,
                  crossAxisSpacing: 12,
                ),
                itemCount: stickers.length,
                itemBuilder: (_, index) {
                  final sticker = stickers[index];
                  return InkWell(
                    onTap: () => widget.onSticker(sticker.id),
                    child: Column(
                      children: [
                        Image.memory(
                          base64Decode(sticker.data.split(',').last),
                          height: 58,
                          fit: BoxFit.contain,
                          errorBuilder: (_, _, _) => const SizedBox(
                            height: 58,
                            child: Icon(Icons.broken_image_outlined),
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          sticker.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 10,
                            color: Color(0xff777777),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      );
    }
    final rowHeight = qq
        ? 85.0
        : MediaQuery.sizeOf(context).width <= 340
        ? 95.0
        : 105.0;
    return Column(
      key: const ValueKey('social-inline-tools'),
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: rowHeight * 2 + (qq ? 29 : 17),
          child: PageView.builder(
            controller: _pages,
            itemCount: pages.length,
            onPageChanged: (value) => setState(() => _page = value),
            itemBuilder: (_, page) => GridView.builder(
              physics: const NeverScrollableScrollPhysics(),
              padding: EdgeInsets.fromLTRB(
                qq ? 0 : 3,
                qq ? 11 : 4,
                qq ? 0 : 3,
                7,
              ),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                mainAxisExtent: rowHeight,
                mainAxisSpacing: qq ? 9 : 5,
              ),
              itemCount: pages[page].length,
              itemBuilder: (_, index) {
                final tool = pages[page][index];
                return Semantics(
                  button: true,
                  enabled: !tool.disabled,
                  label: tool.label,
                  child: InkWell(
                    onTap: tool.disabled
                        ? null
                        : () => widget.onAction(tool.action),
                    child: Opacity(
                      opacity: tool.disabled ? .5 : 1,
                      child: Column(
                        mainAxisAlignment: qq
                            ? MainAxisAlignment.center
                            : MainAxisAlignment.start,
                        children: [
                          Container(
                            padding: EdgeInsets.all(qq ? 11 : 15),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(qq ? 15 : 14),
                            ),
                            child: NativeSocialIcon(
                              tool.icon,
                              size: qq ? 31 : 29,
                              color: const Color(0xff25282e),
                            ),
                          ),
                          SizedBox(
                            height: qq
                                ? tool.disabled
                                      ? 5
                                      : 10
                                : 9,
                          ),
                          Text(
                            tool.label,
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.2,
                              color: Color(qq ? 0xff373941 : 0xff777777),
                            ),
                          ),
                          if (tool.disabled)
                            const Text(
                              '开发中',
                              style: TextStyle(
                                fontSize: 10,
                                height: 1,
                                color: Color(0xff858585),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < pages.length; i++)
              SizedBox(
                width: 22,
                height: 24,
                child: IconButton(
                  tooltip: '更多功能第 ${i + 1} 页',
                  padding: EdgeInsets.zero,
                  onPressed: () => _pages.animateToPage(
                    i,
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOut,
                  ),
                  icon: Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: _page == i
                          ? const Color(0xff80858e)
                          : const Color(0xffcdd0d8),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

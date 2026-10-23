import 'package:flutter/material.dart';
import 'thinking_disclosure.dart';

/// Shared by real replies and the appearance preview. Callers supply the
/// normal chat inset; full replies retain a 16px outer reading margin.
class AssistantReplyLayout extends StatelessWidget {
  const AssistantReplyLayout({
    super.key,
    required this.layout,
    required this.child,
    this.avatar,
    this.thinking,
    this.wide = false,
    this.thinkingColor,
    this.thinkingFontFamily,
  });
  final String layout;
  final Widget child;
  final Widget? avatar;
  final String? thinking;
  final bool wide;
  final Color? thinkingColor;
  final String? thinkingFontFamily;

  static EdgeInsets bubblePadding(String layout) =>
      EdgeInsets.symmetric(horizontal: layout == 'full' ? 8 : 16, vertical: 13);

  @override
  Widget build(BuildContext context) {
    final full = layout == 'full';
    final fill = layout != 'centered';
    final hasThinking = thinking?.isNotEmpty == true;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: full ? (wide ? 8 : 2) : 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!full && avatar != null) ...[avatar!, const SizedBox(width: 9)],
          Flexible(
            fit: fill ? FlexFit.tight : FlexFit.loose,
            child: Padding(
              padding: EdgeInsets.only(right: fill ? 0 : 40),
              child: Column(
                crossAxisAlignment: fill
                    ? CrossAxisAlignment.stretch
                    : CrossAxisAlignment.start,
                children: [
                  if (hasThinking)
                    ThinkingDisclosure(
                      text: thinking!,
                      leading: full ? avatar : null,
                      color: thinkingColor,
                      fontFamily: thinkingFontFamily,
                    )
                  else if (full && avatar != null)
                    Align(alignment: Alignment.centerLeft, child: avatar),
                  // Leave room for the optical rim as well as the header.
                  // A zero gap makes the rim paint over the full-mode avatar.
                  if (hasThinking || (full && avatar != null))
                    const SizedBox(height: 12),
                  child,
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

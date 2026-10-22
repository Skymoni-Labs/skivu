import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'glass_preferences.dart';
import 'state.dart';
import 'appearance.dart';

TextStyle chatMessageStyle(
  BuildContext context,
  bool user, {
  double size = 14,
}) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return TextStyle(
    fontSize: size,
    height: 1.75,
    fontFamily: appearance.fontFamily(user ? 'userFont' : 'assistantFont'),
    fontFamilyFallback: const ['SkiSans'],
    color: appearance.flag('customMessageColors')
        ? appearance.color(user ? 'userText' : 'assistantText')
        : dark
        ? Colors.white
        : user
        ? const Color(0xff285c7a)
        : ink,
  );
}

/// Frost only the backdrop. Text keeps the same layout and sharp foreground.
class ChatBubbleSurface extends StatelessWidget {
  const ChatBubbleSurface({
    super.key,
    required this.user,
    required this.child,
    this.preferences,
    this.backdropKey,
  });
  final bool user;
  final Widget child;
  final GlassPreferences? preferences;
  final BackdropKey? backdropKey;

  @override
  Widget build(BuildContext context) {
    final model = preferences ?? glassPreferences;
    return AnimatedBuilder(
      animation: Listenable.merge([model, appearance]),
      child: child,
      builder: (context, content) {
        final blur = user ? model.userBlur : model.assistantBlur;
        final glass = demo.prefs['毛玻璃效果'] ?? true;
        final dark = Theme.of(context).brightness == Brightness.dark;
        final document = appearance.text('bubbleStyle') == 'document' && !user;
        final alpha = appearance.number(
          user ? 'userOpacity' : 'assistantOpacity',
        );
        final image = appearanceAssets.image(
          appearance.text(user ? 'userImage' : 'assistantImage'),
        );
        final radius = !appearance.flag('rounded')
            ? BorderRadius.circular(3)
            : BorderRadius.only(
                topLeft: Radius.circular(user ? 21 : 6),
                topRight: Radius.circular(user ? 6 : 21),
                bottomLeft: const Radius.circular(21),
                bottomRight: const Radius.circular(21),
              );
        return DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: radius,
            boxShadow: document
                ? []
                : [
                    BoxShadow(
                      color: const Color(0xff8dabc8).withValues(alpha: .035),
                      blurRadius: 8,
                      offset: const Offset(0, 3),
                    ),
                  ],
          ),
          child: ClipRRect(
            borderRadius: radius,
            child: BackdropFilter(
              enabled: glass && blur > 0 && !document,
              backdropGroupKey: backdropKey,
              filter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 13,
                ),
                decoration: BoxDecoration(
                  color: document
                      ? Colors.transparent
                      : appearance.flag('customMessageColors')
                      ? appearance
                            .color(user ? 'userColor' : 'assistantColor')
                            .withValues(alpha: glass ? alpha : 1)
                      : dark
                      ? const Color(
                          0xff2a3b50,
                        ).withValues(alpha: glass ? alpha : .96)
                      : Colors.white.withValues(alpha: glass ? alpha : .96),
                  image: image == null
                      ? null
                      : DecorationImage(
                          image: MemoryImage(image),
                          fit: BoxFit.cover,
                          opacity: alpha,
                        ),
                  borderRadius: radius,
                  border: document
                      ? null
                      : Border.all(
                          color: dark
                              ? Colors.white.withValues(alpha: .08)
                              : Colors.white.withValues(alpha: .86),
                        ),
                ),
                child: content!,
              ),
            ),
          ),
        );
      },
    );
  }
}

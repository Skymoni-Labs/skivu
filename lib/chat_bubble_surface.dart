import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'glass_preferences.dart';
import 'state.dart';
import 'appearance.dart';
import 'chat_backdrop.dart';

TextStyle chatMessageStyle(
  BuildContext context,
  bool user, {
  double size = 14,
  AppearancePreferences? preferences,
}) {
  final model = preferences ?? appearance;
  return TextStyle(
    fontSize: size,
    height: 1.75,
    fontFamily: model.fontFamily(user ? 'userFont' : 'assistantFont'),
    fontFamilyFallback: const ['SkiSans'],
    color: model.textColor(user ? 'userText' : 'assistantText'),
  );
}

/// Frost only the backdrop. Text keeps the same layout and sharp foreground.
class ChatBubbleSurface extends StatelessWidget {
  const ChatBubbleSurface({
    super.key,
    required this.user,
    required this.child,
    this.preferences,
    this.contentPadding = const EdgeInsets.symmetric(
      horizontal: 16,
      vertical: 13,
    ),
  });
  final bool user;
  final Widget child;
  final GlassPreferences? preferences;
  final EdgeInsets contentPadding;

  @override
  Widget build(BuildContext context) {
    final model = preferences ?? glassPreferences;
    final backdrop = ChatBackdropScope.maybeOf(context);
    return AnimatedBuilder(
      animation: Listenable.merge([
        model,
        appearance,
        if (backdrop != null) backdrop,
      ]),
      child: child,
      builder: (context, content) {
        final blur = user ? model.userBlur : model.assistantBlur;
        final glass = demo.prefs['毛玻璃效果'] ?? true;
        final document = appearance.text('bubbleStyle') == 'document' && !user;
        final alpha = appearance.number(
          user ? 'userOpacity' : 'assistantOpacity',
        );
        final image = appearanceAssets.image(
          appearance.text(user ? 'userImage' : 'assistantImage'),
        );
        final shape = appearance.text('bubbleShape');
        final radius = !appearance.flag('rounded') || shape == 'rectangle'
            ? BorderRadius.circular(2)
            : shape == 'tail'
            ? BorderRadius.only(
                topLeft: Radius.circular(user ? 22 : 5),
                topRight: Radius.circular(user ? 5 : 22),
                bottomLeft: const Radius.circular(22),
                bottomRight: const Radius.circular(22),
              )
            : BorderRadius.circular(shape == 'pill' ? 30 : 18);
        final cached = glass && !document ? backdrop?.imageFor(blur) : null;
        Widget material(Widget fill) => cached != null
            ? ChatBackdropPaint(image: cached, source: backdrop!, child: fill)
            : BackdropFilter(
                enabled: glass && blur > 0 && !document,
                filter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
                child: fill,
              );
        return CustomPaint(
          // Paint the rim after the filter and explicitly exclude its interior.
          // Otherwise a solid white shadow becomes part of the blur input.
          foregroundPainter: document ? null : _BubbleRim(radius),
          child: ClipRRect(
            borderRadius: radius,
            child: material(
              Container(
                padding: contentPadding,
                decoration: BoxDecoration(
                  color: document
                      ? Colors.transparent
                      : appearance.flag('customMessageColors')
                      ? appearance
                            .color(user ? 'userColor' : 'assistantColor')
                            .withValues(alpha: glass ? alpha : 1)
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
                          color: Colors.white.withValues(alpha: .9),
                          width: 1.2,
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

class _BubbleRim extends CustomPainter {
  const _BubbleRim(this.radius);
  final BorderRadius radius;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final outline = radius.toRRect(rect);
    final outside = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(rect.inflate(24))
      ..addRRect(outline);
    canvas.save();
    canvas.clipPath(outside);
    canvas.drawRRect(
      outline.shift(const Offset(0, 5)),
      Paint()
        ..color = const Color(0x21233344)
        ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 9),
    );
    canvas.drawRRect(
      outline.inflate(.6),
      Paint()
        ..color = const Color(0xccffffff)
        ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 1.6),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_BubbleRim oldDelegate) => oldDelegate.radius != radius;
}

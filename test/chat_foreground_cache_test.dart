import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/chat_bubble_surface.dart';

class _PaintCounter extends CustomPainter {
  _PaintCounter(this.color, this.onPaint);
  final Color color;
  final VoidCallback onPaint;
  @override
  void paint(Canvas canvas, Size size) {
    onPaint();
    canvas.drawRect(Offset.zero & size, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_PaintCounter oldDelegate) => oldDelegate.color != color;
}

void main() {
  testWidgets(
    'bubble foreground retains paint while scrolling and updates when content changes',
    (tester) async {
      final scroll = ScrollController();
      final color = ValueNotifier(Colors.red);
      var paints = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: SingleChildScrollView(
            controller: scroll,
            child: Column(
              children: [
                const SizedBox(height: 100),
                ChatBubbleSurface(
                  user: false,
                  child: ValueListenableBuilder<Color>(
                    valueListenable: color,
                    builder: (_, value, _) => CustomPaint(
                      painter: _PaintCounter(value, () => paints++),
                      child: const SizedBox(width: 150, height: 250),
                    ),
                  ),
                ),
                const SizedBox(height: 1500),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final initial = paints;
      expect(initial, greaterThan(0));
      for (var i = 0; i < 20; i++) {
        scroll.jumpTo(20 + i * 4);
        await tester.pump(const Duration(milliseconds: 8));
      }
      expect(paints, initial);
      color.value = Colors.green;
      await tester.pump();
      expect(paints, initial + 1);
      await tester.pumpWidget(const SizedBox());
      scroll.dispose();
      color.dispose();
    },
  );
}

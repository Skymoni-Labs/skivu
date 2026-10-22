import 'package:flutter_test/flutter_test.dart';
import 'package:ski/stream_reveal.dart';

void main() {
  testWidgets(
    'a burst is revealed over frames without splitting Unicode or losing text',
    (tester) async {
      final frames = <String>[];
      var shown = '', thinking = '';
      final queue = StreamReveal((text, reason) {
        shown += text;
        thinking += reason;
        frames.add(text);
      });
      final text = List.filled(15, '你好👩🏽‍💻e\u0301').join();
      queue.add(text, '分析');
      expect(shown, isEmpty);
      await tester.pump(const Duration(milliseconds: 16));
      expect(shown.length, lessThan(text.length));
      var finished = false;
      queue.finish().then((_) => finished = true);
      for (var i = 0; i < 90 && !finished; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(finished, isTrue);
      expect(shown, text);
      expect(thinking, '分析');
      expect(frames.where((s) => s.contains('\uFFFD')), isEmpty);
      // No intermediate frame is a prefix inside an emoji/combining cluster.
      for (final frame in frames) {
        expect(frame.endsWith('\u200D'), isFalse);
        expect(frame.endsWith('e'), isFalse);
      }
      queue.dispose();
    },
  );
  testWidgets(
    'stop flushes the received prefix and disposed queues ignore late data',
    (tester) async {
      var output = '';
      final queue = StreamReveal((text, _) => output += text);
      queue.add('尚未显示的回复', '');
      queue.flush();
      queue.dispose();
      queue.add('晚到内容', '');
      await tester.pump(const Duration(seconds: 1));
      expect(output, '尚未显示的回复');
      await queue.finish();
    },
  );
}

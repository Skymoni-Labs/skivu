import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/cloud_companion_portrait.dart';
import 'package:ski/cloud_companion_painter.dart';

void main() {
  Future<void> decode(WidgetTester tester) async {
    for (
      var i = 0;
      i < 300 && find.byIcon(Icons.cloud_outlined).evaluate().isNotEmpty;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
  }

  testWidgets('long press previews locally and resumes the host on close', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: CloudCompanionPortrait())),
    );
    await decode(tester);
    await tester.longPress(
      find.byKey(const ValueKey('cloud-companion-portrait')),
    );
    await tester.pump(const Duration(milliseconds: 400));
    await decode(tester);
    expect(find.text('动作预览'), findsOneWidget);
    final portraits = tester
        .widgetList<CloudCompanionPortrait>(find.byType(CloudCompanionPortrait))
        .toList();
    expect(portraits.length, 2);
    expect(portraits.last.previewEnabled, false);
    final paintings = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((w) => w.painter)
        .whereType<CloudCompanionPainter>()
        .toList();
    expect(paintings.first.motion, false);
    final coding = find.widgetWithText(ChoiceChip, '编程');
    await tester.ensureVisible(coding);
    await tester.tap(coding);
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.text('演示：正在执行代码'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 400));
    final previewPainter = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((w) => w.painter)
        .whereType<CloudCompanionPainter>()
        .last;
    expect(previewPainter.activity, CloudActivity.coding);
    expect(previewPainter.motion, true);
    expect(previewPainter.entry, 1);
    final close = find.byTooltip('关闭预览');
    await tester.ensureVisible(close);
    await tester.tap(close);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('动作预览'), findsNothing);
    final mainPainter = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((w) => w.painter)
        .whereType<CloudCompanionPainter>()
        .single;
    expect(mainPainter.activity, CloudActivity.idle);
    expect(mainPainter.motion, true);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('preview respects reduced motion on a small enlarged screen', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 568));
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 568),
            textScaler: TextScaler.linear(1.5),
          ),
          child: const Scaffold(
            body: CloudCompanionPreview(reduceMotion: true),
          ),
        ),
      ),
    );
    await decode(tester);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '播放全流程'))
          .onPressed,
      isNull,
    );
    final failed = find.widgetWithText(ChoiceChip, '异常');
    await tester.ensureVisible(failed);
    await tester.tap(failed);
    await tester.pumpAndSettle();
    expect(find.text('演示：遇到问题了'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets(
    'approved artwork decodes, idle stays alive and reduced motion remains still',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: CloudCompanionPortrait())),
      );
      final portrait = find.byKey(const ValueKey('cloud-companion-portrait'));
      for (
        var i = 0;
        i < 300 && find.byIcon(Icons.cloud_outlined).evaluate().isNotEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      await tester.pump(const Duration(milliseconds: 4200));
      expect(
        find.byIcon(Icons.cloud_outlined),
        findsNothing,
        reason: 'Use the actual decoded character, not a logo fallback',
      );
      expect(
        find.descendant(of: portrait, matching: find.byType(CustomPaint)),
        findsOneWidget,
      );
      await tester.tap(portrait);
      await tester.pump(const Duration(milliseconds: 250));
      expect(tester.binding.transientCallbackCount, greaterThan(0));
      await tester.pump(const Duration(seconds: 3));
      expect(tester.binding.transientCallbackCount, greaterThan(0));
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: CloudCompanionPortrait(reduceMotion: true)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(portrait);
      await tester.pump();
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );
}

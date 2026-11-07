// Run explicitly with flutter test; not part of the normal test/ suite.
// Exports frames rendered by the production widget, not a separate animation.
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/cloud_companion_portrait.dart';

void main() {
  testWidgets(
    'export real character animation frames',
    (tester) async {
      const output = String.fromEnvironment('CLOUD_EXPORT_DIR');
      if (output.isEmpty) return;
      await tester.binding.setSurfaceSize(const Size(400, 500));
      final loader = FontLoader('SkiSans')
        ..addFont(rootBundle.load('assets/fonts/NotoSansSC.ttf'));
      await tester.runAsync(loader.load);
      const loopOnly = bool.fromEnvironment('CLOUD_LOOP_ONLY');
      const museDemo = bool.fromEnvironment('CLOUD_MUSE_DEMO');
      const fullWorkflow = bool.fromEnvironment('CLOUD_FULL_WORKFLOW');
      final activity = ValueNotifier(
        loopOnly ? CloudActivity.coding : CloudActivity.idle,
      );
      final boundary = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(fontFamily: 'SkiSans'),
          home: Scaffold(
            body: Center(
              child: RepaintBoundary(
                key: boundary,
                child: Container(
                  width: 400,
                  height: 500,
                  color: const Color(0xffeff8ff),
                  child: ValueListenableBuilder<CloudActivity>(
                    valueListenable: activity,
                    builder: (context, state, _) => Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text(
                          '小云 · 动作预览',
                          style: TextStyle(
                            fontSize: 16,
                            color: Color(0xff5280a1),
                          ),
                        ),
                        const SizedBox(height: 12),
                        CloudCompanionPortrait(size: 340, activity: state),
                        const SizedBox(height: 12),
                        Text(
                          state.label,
                          style: const TextStyle(
                            fontSize: 18,
                            color: Color(0xff285675),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
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
      expect(find.byIcon(Icons.cloud_outlined), findsNothing);
      final dir = Directory(output);
      await tester.runAsync(() => dir.create(recursive: true));
      const fps = int.fromEnvironment('CLOUD_FPS', defaultValue: 20);
      const sequence = loopOnly
          ? [(0, CloudActivity.coding)]
          : fullWorkflow
          ? [
              (0, CloudActivity.idle),
              (3000, CloudActivity.thinking),
              (6000, CloudActivity.coding),
              (12000, CloudActivity.phone),
              (15500, CloudActivity.permission),
              (18500, CloudActivity.checking),
              (22000, CloudActivity.resultReady),
              (24500, CloudActivity.complete),
              (27500, CloudActivity.stopping),
              (30000, CloudActivity.paused),
              (32500, CloudActivity.failed),
              (35500, CloudActivity.idle),
            ]
          : museDemo
          ? [
              (0, CloudActivity.idle),
              (1500, CloudActivity.coding),
              (7000, CloudActivity.thinking),
              (8000, CloudActivity.coding),
              (10500, CloudActivity.idle),
            ]
          : [
              (0, CloudActivity.idle),
              (18, CloudActivity.thinking),
              (44, CloudActivity.coding),
              (124, CloudActivity.thinking),
              (142, CloudActivity.coding),
              (170, CloudActivity.permission),
              (200, CloudActivity.coding),
              (224, CloudActivity.checking),
              (250, CloudActivity.complete),
              (278, CloudActivity.idle),
              (294, CloudActivity.phone),
              (334, CloudActivity.stopping),
              (343, CloudActivity.paused),
              (358, CloudActivity.failed),
              (382, CloudActivity.idle),
            ];
      final manifest = <String>[];
      final count = loopOnly
          ? 8 * fps
          : fullWorkflow
          ? 38 * fps
          : museDemo
          ? 12 * fps
          : (402 * fps / 20).round();
      var previousMicros = 0;
      for (var frame = 0; frame < count; frame++) {
        for (final (start, state) in sequence) {
          final at =
              (start *
                      fps /
                      ((museDemo || fullWorkflow) && !loopOnly ? 1000 : 20))
                  .round();
          if (at == frame) {
            activity.value = state;
            manifest.add('$frame,${state.name}');
            if (fullWorkflow && state == CloudActivity.idle) {
              await tester.pump();
              await tester.tap(
                find.byKey(const ValueKey('cloud-companion-portrait')),
              );
            }
          }
        }
        final targetMicros = ((frame + 1) * 1000000 / fps).round();
        await tester.pump(
          Duration(microseconds: targetMicros - previousMicros),
        );
        previousMicros = targetMicros;
        final renderer =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await renderer.toImage(pixelRatio: 1.2);
          try {
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            await File(
              '${dir.path}/frame-${frame.toString().padLeft(4, '0')}.png',
            ).writeAsBytes(data!.buffer.asUint8List());
          } finally {
            image.dispose();
          }
        });
      }
      await tester.runAsync(
        () => File(
          '${dir.path}/states.csv',
        ).writeAsString('frame,state\n${manifest.join('\n')}\n'),
      );
      await tester.runAsync(
        () => File('${dir.path}/video-timing.txt').writeAsString(
          'fps=$fps\nframes=$count\nduration_seconds=${count / fps}\n',
        ),
      );
      await tester.pumpWidget(const SizedBox());
      activity.dispose();
      await tester.binding.setSurfaceSize(null);
      expect(tester.takeException(), isNull);
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

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
      const fps = 20;
      const sequence = loopOnly
          ? [(0, CloudActivity.coding)]
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
      for (var frame = 0; frame < (loopOnly ? 160 : 402); frame++) {
        for (final (start, state) in sequence) {
          if (start == frame) {
            activity.value = state;
            manifest.add('$frame,${state.name}');
          }
        }
        await tester.pump(const Duration(milliseconds: 1000 ~/ fps));
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
      await tester.pumpWidget(const SizedBox());
      activity.dispose();
      await tester.binding.setSurfaceSize(null);
      expect(tester.takeException(), isNull);
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

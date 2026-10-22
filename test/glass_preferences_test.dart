import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';
import 'package:ski/drawer_motion.dart';
import 'package:ski/glass.dart';
import 'package:ski/glass_preferences.dart';
import 'package:ski/glass_settings.dart';

class MemoryGlassPreferences implements GlassPreferencesPersistence {
  GlassBlurValues? saved;
  bool failRead = false;
  Future<void> Function()? beforeWrite;
  @override
  Future<GlassBlurValues?> read() async {
    if (failRead) throw StateError('Unavailable');
    return saved;
  }

  @override
  Future<void> write(GlassBlurValues values) async {
    await beforeWrite?.call();
    saved = values;
  }
}

void main() {
  test(
    'older sidebar data migrates and bubble reset stays independent',
    () async {
      final old = decodeGlassBlurValues('{"left":24,"right":8}');
      expect(old, (left: 24.0, right: 8.0, user: 0.0, assistant: 0.0));
      final disk = MemoryGlassPreferences()..saved = old;
      final model = GlassPreferences(persistence: disk);
      await model.restore();
      model.setBubbleBlur(user: true, value: 18);
      model.setBubbleBlur(user: false, value: 6);
      await model.save();
      final restarted = GlassPreferences(persistence: disk);
      await restarted.restore();
      expect(restarted.userBlur, 18);
      expect(restarted.assistantBlur, 6);
      await restarted.reset();
      expect(restarted.userBlur, 18);
      expect(restarted.assistantBlur, 6);
      restarted.setBlur(leftSide: true, value: 24);
      await restarted.resetBubbles();
      expect(disk.saved, (left: 24.0, right: 12.0, user: 0.0, assistant: 0.0));
      restarted.setBubbleBlur(user: true, value: double.infinity);
      restarted.setBubbleBlur(user: false, value: -10);
      expect(restarted.userBlur, 0);
      expect(restarted.assistantBlur, 0);
      model.dispose();
      restarted.dispose();
    },
  );

  test('independent values survive restart, stay bounded and reset', () async {
    final disk = MemoryGlassPreferences();
    final model = GlassPreferences(persistence: disk);
    expect(model.leftBlur, 12);
    expect(model.rightBlur, 12);
    model.setBlur(leftSide: true, value: 8);
    model.setBlur(leftSide: false, value: 27);
    await model.save();
    final restarted = GlassPreferences(persistence: disk);
    await restarted.restore();
    expect(restarted.leftBlur, 8);
    expect(restarted.rightBlur, 27);
    restarted.setBlur(leftSide: true, value: 100);
    restarted.setBlur(leftSide: false, value: double.nan);
    expect(restarted.leftBlur, 30);
    expect(restarted.rightBlur, 27);
    await restarted.reset();
    expect(disk.saved, (left: 12.0, right: 12.0, user: 0.0, assistant: 0.0));
    disk.failRead = true;
    restarted.setBlur(leftSide: true, value: 2);
    await restarted.restore();
    expect(restarted.leftBlur, 12);
    expect(restarted.error, isNotNull);
    model.dispose();
    restarted.dispose();
  });

  test(
    'rapid saves remain ordered and an old failure cannot mask a newer save',
    () async {
      final blocked = Completer<void>();
      var writes = 0;
      final disk = MemoryGlassPreferences()
        ..beforeWrite = () async {
          if (writes++ == 0) {
            await blocked.future;
            throw StateError('First write failed');
          }
        };
      final model = GlassPreferences(persistence: disk);
      model.setBlur(leftSide: true, value: 4);
      final first = model.save();
      model.setBlur(leftSide: false, value: 30);
      final second = model.save();
      expect(writes, 1);
      blocked.complete();
      await Future.wait([first, second]);
      expect(disk.saved, (left: 4.0, right: 30.0, user: 0.0, assistant: 0.0));
      expect(model.error, isNull);
      disk.beforeWrite = () async => throw StateError('Storage full');
      await model.save();
      expect(model.error, isNotNull);
      expect(model.leftBlur, 4);
      expect(model.rightBlur, 30);
      disk.beforeWrite = null;
      await model.save();
      expect(model.error, isNull);
      model.dispose();
    },
  );

  testWidgets('panel blur updates live without rebuilding panel text', (
    tester,
  ) async {
    final model = GlassPreferences(persistence: MemoryGlassPreferences());
    final motion = DrawerMotion(vsync: tester);
    var builds = 0;
    Widget panel(bool left) => SkiGlassPanel(
      leftSide: left,
      preferences: model,
      child: Builder(
        builder: (_) {
          builds++;
          return const SizedBox.expand();
        },
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: SkiGlassScene(
          motion: motion,
          child: SlideDeck(
            motion: motion,
            left: panel(true),
            right: panel(false),
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
    double blur() => tester
        .widget<LiquidGlassLens>(find.byKey(const ValueKey('side-sheet-fill')))
        .style
        .blur;
    motion.toggle(1);
    await tester.pumpAndSettle();
    final before = builds;
    expect(blur(), 12);
    model.setBlur(leftSide: true, value: 0);
    model.setBlur(leftSide: false, value: 30);
    await tester.pumpAndSettle();
    expect(blur(), 0);
    expect(builds, before);
    motion.close();
    await tester.pumpAndSettle();
    motion.toggle(-1);
    await tester.pumpAndSettle();
    expect(blur(), 30);
    final rightBuilds = builds;
    await model.reset();
    await tester.pumpAndSettle();
    expect(blur(), 12);
    expect(builds, rightBuilds);
    await tester.pumpWidget(const SizedBox());
    motion.dispose();
    model.dispose();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'narrow settings sliders save and preview the corresponding side',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final disk = MemoryGlassPreferences();
      final model = GlassPreferences(persistence: disk);
      final motion = DrawerMotion(vsync: tester);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.2)),
            child: Scaffold(
              body: SlideDeck(
                motion: motion,
                left: const SizedBox.expand(key: ValueKey('left-preview')),
                right: const SizedBox.expand(key: ValueKey('right-preview')),
                child: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.all(42),
                    child: GlassSettings(preferences: model),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.drag(
        find.byKey(const ValueKey('left-glass-blur')),
        const Offset(-200, 0),
      );
      await tester.pumpAndSettle();
      await tester.drag(
        find.byKey(const ValueKey('right-glass-blur')),
        const Offset(200, 0),
      );
      await tester.pumpAndSettle();
      expect(disk.saved, (left: 0.0, right: 30.0, user: 0.0, assistant: 0.0));
      await tester.tap(find.text('预览左侧'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('left-preview')), findsOneWidget);
      motion.close();
      await tester.pumpAndSettle();
      await tester.tap(find.text('预览右侧'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('right-preview')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      motion.dispose();
      model.dispose();
      expect(tester.takeException(), isNull);
    },
  );
}

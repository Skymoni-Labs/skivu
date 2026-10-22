import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/chat_bubble_surface.dart';
import 'package:ski/glass_preferences.dart';
import 'package:ski/glass_settings.dart';
import 'package:ski/state.dart';
import 'package:ski/appearance.dart';
import 'glass_preferences_test.dart' show MemoryGlassPreferences;

void main() {
  testWidgets('both dark and light bubbles obey independent opacity', (
    tester,
  ) async {
    final old = appearance.values;
    addTearDown(() {
      for (final e in old.entries) {
        appearance.set(e.key, e.value);
      }
    });
    appearance.set('userOpacity', .17);
    appearance.set('assistantOpacity', .91);
    for (final dark in [true, false]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            brightness: dark ? Brightness.dark : Brightness.light,
          ),
          home: const Column(
            children: [
              ChatBubbleSurface(
                key: ValueKey('user-alpha'),
                user: true,
                child: Text('清晰的文字'),
              ),
              ChatBubbleSurface(
                key: ValueKey('reply-alpha'),
                user: false,
                child: Text('回复'),
              ),
            ],
          ),
        ),
      );
      for (final user in [true, false]) {
        final containers = tester.widgetList<Container>(
          find.descendant(
            of: find.byKey(ValueKey(user ? 'user-alpha' : 'reply-alpha')),
            matching: find.byType(Container),
          ),
        );
        final paint =
            containers
                    .firstWhere((w) => w.decoration is BoxDecoration)
                    .decoration!
                as BoxDecoration;
        expect(paint.color!.a, closeTo(user ? .17 : .91, .001));
      }
    }
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'role blur changes the backdrop while text and layout stay stable',
    (tester) async {
      final model = GlassPreferences(persistence: MemoryGlassPreferences());
      final userKey = BackdropKey(), replyKey = BackdropKey();
      var builds = 0;
      Widget bubble(bool user) => ChatBubbleSurface(
        key: ValueKey(user ? 'mine' : 'reply'),
        user: user,
        preferences: model,
        backdropKey: user ? userKey : replyKey,
        child: Builder(
          builder: (_) {
            builds++;
            return Text(user ? '今天想聊一会儿。' : '我在，慢慢说。');
          },
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: Column(children: [bubble(true), bubble(false)])),
        ),
      );
      Finder surface(bool user) =>
          find.byKey(ValueKey(user ? 'mine' : 'reply'));
      BackdropFilter filter(bool user) => tester.widget<BackdropFilter>(
        find.descendant(
          of: surface(user),
          matching: find.byType(BackdropFilter),
        ),
      );
      final oldSize = tester.getSize(surface(true));
      final oldBuilds = builds;
      expect(filter(true).enabled, isFalse);
      expect(filter(false).enabled, isFalse);
      model.setBubbleBlur(user: true, value: 25);
      await tester.pump();
      expect(filter(true).enabled, isTrue);
      expect(filter(true).filter, ui.ImageFilter.blur(sigmaX: 25, sigmaY: 25));
      expect(filter(false).enabled, isFalse);
      model.setBubbleBlur(user: false, value: 8);
      await tester.pump();
      expect(filter(false).filter, ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8));
      expect(filter(true).backdropGroupKey, userKey);
      expect(filter(false).backdropGroupKey, replyKey);
      expect(builds, oldBuilds);
      expect(tester.getSize(surface(true)), oldSize);
      expect(
        find.ancestor(
          of: find.text('今天想聊一会儿。'),
          matching: find.byType(ImageFiltered),
        ),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox());
      model.dispose();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'narrow bubble controls save independently and obey glass switch',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final oldGlass = demo.prefs['毛玻璃效果'];
      demo.prefs['毛玻璃效果'] = true;
      addTearDown(() {
        demo.prefs['毛玻璃效果'] = oldGlass!;
      });
      final disk = MemoryGlassPreferences();
      final model = GlassPreferences(persistence: disk);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.2)),
            child: Scaffold(
              body: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(42),
                  child: BubbleGlassSettings(preferences: model),
                ),
              ),
            ),
          ),
        ),
      );
      for (final key in ['user-bubble-blur', 'assistant-bubble-blur']) {
        await tester.drag(find.byKey(ValueKey(key)), const Offset(200, 0));
        await tester.pumpAndSettle();
      }
      expect(disk.saved, (
        left: 12.0,
        right: 12.0,
        user: 30.0,
        assistant: 30.0,
      ));
      expect(
        tester
            .widgetList<BackdropFilter>(find.byType(BackdropFilter))
            .every((f) => f.enabled),
        isTrue,
      );
      demo.prefs['毛玻璃效果'] = false;
      demo.changed();
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<BackdropFilter>(find.byType(BackdropFilter))
            .every((f) => !f.enabled),
        isTrue,
      );
      await tester.tap(find.text('恢复默认气泡'));
      await tester.pumpAndSettle();
      expect(disk.saved, (left: 12.0, right: 12.0, user: 0.0, assistant: 0.0));
      await tester.pumpWidget(const SizedBox());
      model.dispose();
      expect(tester.takeException(), isNull);
    },
  );
}

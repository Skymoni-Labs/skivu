import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ski/appearance.dart';
import 'package:ski/cloud_companion_portrait.dart';
import 'package:ski/cloud_conversations.dart';
import 'package:ski/main.dart';
import 'package:ski/state.dart';
import 'preview_fixture.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    seedPreviewConversation();
    demo.streaming = false;
    appearance.set('reduceMotion', true);
    appearance.set('capsuleToolbar', true);
    demo.openCloudChat();
  });

  testWidgets('small Cloud portrait is centered in both toolbar shapes', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    for (final width in [320.0, 390.0]) {
      tester.view.physicalSize = Size(width, 844);
      for (final capsule in [true, false]) {
        appearance.set('capsuleToolbar', capsule);
        await tester.pumpWidget(const SkiApp());
        await tester.pumpAndSettle();
        final toolbar = find.byKey(
          ValueKey(capsule ? 'capsule-toolbar' : 'rectangle-toolbar'),
        );
        final mini = find.byKey(const ValueKey('cloud-toolbar-companion'));
        expect(tester.getCenter(mini).dx, tester.getCenter(toolbar).dx);
        expect(tester.getCenter(mini).dy, tester.getCenter(toolbar).dy);
        expect(find.byType(CloudCompanionPortrait), findsOneWidget);
        expect(
          tester
              .widget<CloudCompanionPortrait>(
                find.byType(CloudCompanionPortrait),
              )
              .size,
          44,
        );
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('cloud-chat-header')),
            matching: find.byType(CloudCompanionPortrait),
          ),
          findsNothing,
        );
        expect(find.byKey(const ValueKey('toolbar-title')), findsNothing);
        expect(find.text('手机能力与授权'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Cloud keeps its centered animated status while replying', (
    tester,
  ) async {
    await tester.pumpWidget(const SkiApp());
    await tester.pumpAndSettle();
    final engine = cloudChats.engineFor(demo.conversations[demo.conversation]);
    demo.streaming = true;
    demo.changed();
    await tester.pump();
    expect(find.byKey(const ValueKey('typing-indicator')), findsNothing);
    expect(find.text('对方正在输入中...'), findsNothing);
    expect(
      find.byKey(const ValueKey('cloud-toolbar-companion')),
      findsOneWidget,
    );
    engine.account = cloudChats.identity();
    engine.phase = 'executing';
    engine.pending = {'tool': 'shell.execute'};
    engine.notifyListeners();
    await tester.pump();
    expect(
      tester
          .widget<CloudCompanionPortrait>(find.byType(CloudCompanionPortrait))
          .activity,
      CloudActivity.coding,
    );
    engine.phase = 'idle';
    engine.pending = null;
    engine.notifyListeners();
    demo.streaming = false;
    demo.changed();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('centered Cloud stays exclusive to its chat module', (
    tester,
  ) async {
    await tester.pumpWidget(const SkiApp());
    await tester.pumpAndSettle();
    final chat = demo.conversations[demo.conversation];
    for (final index in [1, 2, 3]) {
      await tester.tap(find.byKey(ValueKey('main-module-$index')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('cloud-toolbar-companion')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('main-module-4')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('cloud-toolbar-companion')),
        findsOneWidget,
      );
      expect(demo.conversations[demo.conversation], same(chat));
    }
    await tester.tap(find.byKey(const ValueKey('main-module-0')));
    await tester.pumpAndSettle();
    expect(demo.isCloudChat, false);
    expect(find.byKey(const ValueKey('cloud-toolbar-companion')), findsNothing);
    demo.streaming = true;
    demo.changed();
    await tester.pump();
    expect(find.byKey(const ValueKey('typing-indicator')), findsOneWidget);
    demo.streaming = false;
    demo.changed();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('toolbar portrait retains its long-press motion preview', (
    tester,
  ) async {
    await tester.pumpWidget(const SkiApp());
    await tester.pumpAndSettle();
    await tester.longPress(
      find.byKey(const ValueKey('cloud-toolbar-companion')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(CloudCompanionPreview), findsOneWidget);
    expect(find.text('动作预览'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}

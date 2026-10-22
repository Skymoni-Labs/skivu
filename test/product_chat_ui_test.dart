import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/appearance.dart';
import 'package:ski/chat_bubble_surface.dart';
import 'package:ski/chat_status_bar.dart';
import 'package:ski/main.dart';
import 'package:ski/state.dart';
import 'package:ski/workspace.dart';
import 'preview_fixture.dart';

void main() {
  setUp(seedPreviewConversation);
  testWidgets(
    'composer usage stays on one line and can be hidden on a small phone',
    (tester) async {
      tester.view.physicalSize = const Size(320, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      appearance.set('showUsage', true);
      await tester.pumpWidget(const SkiApp());
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(ChatStatusBar)).height, lessThan(20));
      appearance.set('showUsage', false);
      await tester.pumpAndSettle();
      expect(find.byType(ChatStatusBar), findsNothing);
      expect(find.byKey(const ValueKey('chat-composer-field')), findsOneWidget);
      appearance.set('showUsage', true);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'typing appears in capsule and rectangle is a completely opaque alternative',
    (tester) async {
      appearance.set('capsuleToolbar', true);
      demo.streaming = true;
      addTearDown(() {
        demo.streaming = false;
        appearance.set('capsuleToolbar', true);
      });
      await tester.pumpWidget(const SkiApp());
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const ValueKey('typing-indicator')), findsOneWidget);
      appearance.set('capsuleToolbar', false);
      await tester.pump();
      final opaque = tester.widget<ColoredBox>(
        find.byKey(const ValueKey('opaque-rectangle-toolbar')),
      );
      expect(opaque.color.a, 1);
      expect(find.byKey(const ValueKey('typing-indicator')), findsOneWidget);
      demo.streaming = false;
      demo.changed();
      await tester.pumpAndSettle();
      expect(find.text('对方正在输入中'), findsNothing);
    },
  );
  testWidgets(
    'avatar opens real role editor and both message colors remain dark',
    (tester) async {
      appearance.set('avatars', true);
      await tester.pumpWidget(const SkiApp());
      await tester.pumpAndSettle();
      final c = tester.element(find.byType(ChatBubbleSurface).first);
      expect(chatMessageStyle(c, true).color, ink);
      expect(chatMessageStyle(c, false).color, ink);
      await tester.tap(find.byTooltip('编辑对话角色卡').first);
      await tester.pumpAndSettle();
      expect(find.text('编辑角色卡'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, '角色描述'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('workspace only shows coming-soon modules', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: WorkspacePanel(close: () {})),
      ),
    );
    expect(find.text('即将开放'), findsNWidgets(4));
    expect(find.text('灵感笔记.md'), findsNothing);
    expect(find.byType(TextField), findsNothing);
  });
}

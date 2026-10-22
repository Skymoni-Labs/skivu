import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/appearance.dart';
import 'package:ski/chat_bubble_surface.dart';
import 'package:ski/chat_status_bar.dart';
import 'package:ski/chat_message_dial.dart';
import 'package:ski/main.dart';
import 'package:ski/state.dart';
import 'package:ski/workspace.dart';
import 'package:ski/glass.dart';
import 'package:ski/thinking_disclosure.dart';
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
      expect(
        find.descendant(
          of: find.byType(ChatStatusBar),
          matching: find.byType(DecoratedBox),
        ),
        findsNothing,
      );
      appearance.set('showUsage', false);
      await tester.pumpAndSettle();
      expect(find.byType(ChatStatusBar), findsNothing);
      expect(find.byKey(const ValueKey('chat-composer-field')), findsOneWidget);
      appearance.set('showUsage', true);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'typing appears in capsule and rectangular glass extends behind status bar',
    (tester) async {
      appearance.set('capsuleToolbar', true);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(top: 32, bottom: 24);
      addTearDown(tester.view.reset);
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
      final rectangle = find.byKey(const ValueKey('glass-rectangle-toolbar'));
      final glass = tester.widget<ConfigurableGlassSurface>(rectangle);
      expect(glass.area, 'toolbarBlur');
      expect(glass.radius, 0);
      final surface = tester.widget<GlassSurface>(
        find
            .descendant(of: rectangle, matching: find.byType(GlassSurface))
            .first,
      );
      expect(surface.outline, isFalse);
      expect(
        tester.getSize(find.byKey(const ValueKey('rectangle-toolbar'))).height,
        48,
      );
      expect(tester.getTopLeft(rectangle).dy, 0);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('rectangle-toolbar'))).dy,
        32,
      );
      expect(find.byKey(const ValueKey('typing-indicator')), findsOneWidget);
      demo.streaming = false;
      demo.changed();
      await tester.pumpAndSettle();
      expect(find.text('对方正在输入中'), findsNothing);
    },
  );
  testWidgets(
    'assistant leaves a right gutter and reasoning is above its bubble',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      appearance.set('showThinking', true);
      demo.messages
        ..clear()
        ..add(
          Message(false, List.filled(12, '这是一段用于检查气泡宽度的回复。').join())
            ..thinking = '这是可折叠的思考摘要。',
        );
      await tester.pumpWidget(const SkiApp());
      await tester.pumpAndSettle();
      final bubble = find.byType(ChatBubbleSurface);
      expect(tester.getBottomRight(bubble).dx, lessThanOrEqualTo(390 - 50));
      expect(
        tester.getBottomLeft(find.byType(ThinkingDisclosure)).dy,
        lessThanOrEqualTo(tester.getTopLeft(bubble).dy),
      );
      await tester.tap(find.text('思考过程'));
      await tester.pumpAndSettle();
      expect(find.text('这是可折叠的思考摘要。'), findsOneWidget);
      appearance.set('showThinking', false);
      await tester.pumpAndSettle();
      expect(find.byType(ThinkingDisclosure), findsNothing);
      appearance.set('showThinking', true);
      expect(tester.takeException(), isNull);
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
  testWidgets(
    'history control sits above latest and latest resumes bottom following',
    (tester) async {
      demo.messages
        ..clear()
        ..addAll(
          List.generate(
            16,
            (i) => Message(
              i.isEven,
              '消息 $i：${List.filled(8, '用于检查定位的长内容。').join()}',
            ),
          ),
        );
      await tester.pumpWidget(const SkiApp());
      await tester.pumpAndSettle();
      demo.changed();
      await tester.pumpAndSettle();
      final list = find.byType(ListView).first;
      await tester.drag(list, const Offset(0, 260));
      await tester.pump(const Duration(milliseconds: 100));
      final latest = find.byKey(const ValueKey('chat-jump-latest'));
      final history = find.byKey(
        const ValueKey('chat-message-navigation-ball'),
      );
      expect(latest, findsOneWidget);
      expect(history, findsOneWidget);
      expect(
        tester.getCenter(latest).dy,
        greaterThan(tester.getCenter(history).dy),
      );
      expect(tester.getSize(latest), tester.getSize(history));
      expect(
        tester.getSize(
          find.byKey(const ValueKey('chat-message-latest-surface')),
        ),
        const Size(40, 40),
      );
      expect(
        tester.getSize(
          find.byKey(const ValueKey('chat-message-history-surface')),
        ),
        const Size(40, 40),
      );
      final composer = find.byKey(const ValueKey('chat-composer'));
      expect(
        tester.getBottomRight(latest).dy,
        closeTo(tester.getTopLeft(composer).dy - 14, 1),
      );
      expect(
        tester.getBottomRight(history).dy,
        lessThan(tester.getTopLeft(latest).dy),
      );
      await tester.tap(latest);
      await tester.pumpAndSettle();
      final controller = tester.widget<ListView>(list).controller!;
      expect(
        controller.offset,
        closeTo(controller.position.maxScrollExtent, 1),
      );
      expect(latest, findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('dial preview stays above the ring on a short enlarged phone', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(1.6)),
          child: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                key: const ValueKey('dial-viewport'),
                width: 320,
                height: 340,
                child: ChatMessageDial(
                  visible: true,
                  viewportHeight: 340,
                  currentTimestamp: 0,
                  loadEntries: () async => [
                    ChatMessageLocatorPreview(
                      timestamp: 0,
                      sender: 'assistant',
                      previewContent: List.filled(30, '窄屏下查看长消息。').join(),
                      messageIndex: 0,
                    ),
                  ],
                  onOpenLocator: () {},
                  onJump: (_) {},
                  onHidden: () {},
                  senderName: (_) => '角色',
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final history = find.byKey(const ValueKey('chat-message-navigation-ball'));
    final gesture = await tester.startGesture(tester.getCenter(history));
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump(const Duration(milliseconds: 200));
    final preview = tester.getRect(
      find.byKey(const ValueKey('chat-message-dial-target')),
    );
    final ring = tester.getRect(
      find.byKey(const ValueKey('chat-message-dial-ring')),
    );
    final viewport = tester.getRect(
      find.byKey(const ValueKey('dial-viewport')),
    );
    expect(preview.overlaps(ring), isFalse);
    expect(preview.bottom, lessThanOrEqualTo(ring.top - 12));
    expect(preview.top, greaterThanOrEqualTo(viewport.top + 8));
    expect(viewport.contains(ring.bottomRight - const Offset(1, 1)), isTrue);
    expect(tester.takeException(), isNull);
    await gesture.cancel();
    await tester.pumpWidget(const SizedBox());
  });
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

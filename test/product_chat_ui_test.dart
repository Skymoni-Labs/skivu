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
    'reply width modes preserve user layout and place full reply edge to edge',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final old = appearance.text('assistantBubbleLayout');
      addTearDown(() => appearance.set('assistantBubbleLayout', old));
      appearance.set('avatars', true);
      demo.messages
        ..clear()
        ..addAll([
          Message(true, '我的提问'),
          Message(false, List.filled(12, '宽度检查内容').join()),
        ]);
      appearance.set('assistantBubbleLayout', 'centered');
      await tester.pumpWidget(const SkiApp());
      await tester.pumpAndSettle();
      final reply = find.byKey(const ValueKey('message-bubble-1'));
      final user = find.byKey(const ValueKey('message-bubble-0'));
      final originalUser = tester.getRect(user);
      final centered = tester.getRect(reply);
      appearance.set('assistantBubbleLayout', 'side');
      await tester.pumpAndSettle();
      final side = tester.getRect(reply);
      expect(side.width, greaterThan(centered.width));
      expect(side.left, centered.left);
      expect(tester.getRect(user).left, originalUser.left);
      expect(tester.getRect(user).width, originalUser.width);
      appearance.set('assistantBubbleLayout', 'full');
      await tester.pumpAndSettle();
      final full = tester.getRect(reply);
      expect(full.width, greaterThan(side.width));
      expect(full.left, 0);
      expect(full.right, 390);
      expect(
        tester.getBottomLeft(find.byTooltip('编辑对话角色卡')).dy,
        lessThanOrEqualTo(full.top),
      );
      expect(tester.getRect(user).left, originalUser.left);
      expect(tester.getRect(user).width, originalUser.width);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'bubble round deletion requires confirmation and preserves adjacent turns',
    (tester) async {
      demo.messages
        ..clear()
        ..addAll([
          Message(true, '第一问'),
          Message(false, '第一答'),
          Message(true, '第二问'),
          Message(false, '第二答'),
        ]);
      await tester.pumpWidget(const SkiApp());
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('消息菜单 2'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除本轮对话'));
      await tester.pumpAndSettle();
      expect(find.textContaining('共 2 条消息'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(demo.messages, hasLength(4));
      await tester.tap(find.byTooltip('消息菜单 2'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除本轮对话'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除本轮'));
      await tester.pumpAndSettle();
      expect(demo.messages.map((m) => m.text), ['第二问', '第二答']);
      expect(find.text('第一问'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
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
      expect(find.byKey(const ValueKey('toolbar-title')), findsNothing);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('typing-indicator')))
            .data,
        '对方正在输入中',
      );
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
        64,
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
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('toolbar-title'))).data,
        demo.role.name,
      );
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

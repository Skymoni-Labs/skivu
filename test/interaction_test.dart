import 'preview_fixture.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';
import 'package:ski/main.dart';
import 'package:ski/chat.dart';
import 'package:ski/glass.dart';
import 'package:ski/state.dart';
import 'package:ski/workspace.dart';

void previewTestWidgets(String description, WidgetTesterCallback callback) {
  testWidgets(
    description,
    callback,
    variant: TargetPlatformVariant({TargetPlatform.linux}),
  );
}

void main() {
  setUp(seedPreviewConversation);
  previewTestWidgets(
    'glass preferences retain drafts and touch buttons keep actions',
    (tester) async {
      final oldDark = demo.dark;
      final oldGlass = demo.prefs['毛玻璃效果'];
      final oldReduced = demo.prefs['减少动态效果'];
      addTearDown(() {
        demo.dark = oldDark;
        demo.prefs['毛玻璃效果'] = oldGlass ?? true;
        demo.prefs['减少动态效果'] = oldReduced ?? false;
      });
      demo.dark = false;
      demo.prefs['毛玻璃效果'] = true;
      demo.prefs['减少动态效果'] = false;
      await tester.pumpWidget(const SkiApp());
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '还没发送的想法');
      demo.dark = true;
      demo.changed();
      await tester.pumpAndSettle();
      expect(find.text('还没发送的想法'), findsOneWidget);
      demo.prefs['减少动态效果'] = true;
      demo.changed();
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<LiquidGlassButton>(find.byType(LiquidGlassButton))
            .every((b) => b.touch == null),
        isTrue,
      );
      demo.prefs['毛玻璃效果'] = false;
      demo.changed();
      await tester.pumpAndSettle();
      expect(find.byType(LiquidGlassLens), findsNothing);
      expect(find.text('还没发送的想法'), findsOneWidget);
      demo.prefs['毛玻璃效果'] = true;
      demo.prefs['减少动态效果'] = false;
      demo.changed();
      await tester.pumpAndSettle();
      final press = await tester.startGesture(
        tester.getCenter(find.byTooltip('打开工作区')),
      );
      await tester.pump(const Duration(milliseconds: 150));
      expect(find.byType(WorkspacePanel), findsNothing);
      await press.up();
      await tester.pumpAndSettle();
      expect(find.byType(WorkspacePanel), findsOneWidget);
      expect(
        find.ancestor(
          of: find.byType(WorkspacePanel),
          matching: find.byType(SkiGlassPanel),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(SkiGlassPanel),
          matching: find.byType(LiquidGlassLens),
        ),
        findsOneWidget,
      );
      expect(
        find.ancestor(
          of: find.byType(WorkspacePanel),
          matching: find.byType(LiquidGlassShadow),
        ),
        findsOneWidget,
      );
      final viewport = tester.getRect(find.byType(SkiShell));
      for (final key in ['side-sheet-fill', 'home-sheet-fill']) {
        final sheet = find.byKey(ValueKey(key));
        expect(
          tester.getTopLeft(sheet).dy,
          lessThanOrEqualTo(viewport.top - 18),
        );
        expect(
          tester.getTopRight(sheet).dy,
          lessThanOrEqualTo(viewport.top - 18),
        );
        expect(
          tester.getBottomLeft(sheet).dy,
          greaterThanOrEqualTo(viewport.bottom + 18),
        );
        expect(
          tester.getBottomRight(sheet).dy,
          greaterThanOrEqualTo(viewport.bottom + 18),
        );
      }
      expect(
        tester
            .widgetList<LiquidGlassButton>(find.byType(LiquidGlassButton))
            .every((b) => b.style!.liteGlass),
        isTrue,
      );
      await tester.tap(find.byTooltip('关闭工作区'));
      await tester.pumpAndSettle();
      expect(find.text('还没发送的想法'), findsOneWidget);
      expect(
        tester
            .widgetList<LiquidGlassButton>(find.byType(LiquidGlassButton))
            .every((b) => !b.style!.liteGlass),
        isTrue,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  previewTestWidgets('wide browser still hosts a phone canvas', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const SkiApp());
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(SkiShell)).width, lessThanOrEqualTo(430));
    expect(find.byType(SideNavigation), findsNothing);
    expect(tester.takeException(), isNull);
  });

  previewTestWidgets('all mobile pages render at 360px and enlarged text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    demo.textScale = 1.2;
    addTearDown(() => demo.textScale = 1);
    await tester.pumpWidget(const SkiApp());
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(SkiShell));
    final nav = Navigator.of(context);
    for (final route in [
      '/characters',
      '/characters/edit',
      '/settings',
      '/settings/models',
      '/settings/speech',
      '/settings/appearance',
      '/settings/permissions',
      '/settings/data',
      '/settings/workspace',
      '/settings/devices',
      '/settings/about',
      '/plugins',
      '/market',
      '/call',
    ]) {
      nav.pushReplacementNamed(route);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull, reason: route);
    }
    nav.pushReplacementNamed('/chat');
    await tester.pumpAndSettle();
  });

  previewTestWidgets(
    'drawers follow drag, reverse, cancel, snap and stay exclusive',
    (tester) async {
      tester.view.physicalSize = const Size(430, 932);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const SkiApp());
      await tester.pumpAndSettle();
      expect(find.byType(SideNavigation), findsNothing);
      final reverse = await tester.startGesture(const Offset(170, 300));
      await reverse.moveBy(const Offset(130, 0));
      await tester.pump();
      expect(find.byType(SideNavigation), findsOneWidget);
      await reverse.moveBy(const Offset(-115, 0));
      await tester.pump(const Duration(milliseconds: 500));
      await reverse.up();
      await tester.pumpAndSettle();
      expect(find.byType(SideNavigation), findsNothing);
      final cancel = await tester.startGesture(const Offset(170, 300));
      await cancel.moveBy(const Offset(140, 0));
      await tester.pump();
      await cancel.cancel();
      await tester.pumpAndSettle();
      expect(find.byType(SideNavigation), findsNothing);
      await tester.dragFrom(const Offset(150, 300), const Offset(180, 0));
      await tester.pumpAndSettle();
      expect(find.byType(SideNavigation), findsOneWidget);
      expect(find.byType(WorkspacePanel), findsNothing);
      await tester.tap(find.byTooltip('关闭导航'));
      await tester.pumpAndSettle();
      await tester.dragFrom(const Offset(330, 300), const Offset(-250, 0));
      await tester.pumpAndSettle();
      expect(find.byType(WorkspacePanel), findsOneWidget);
      expect(find.byType(SideNavigation), findsNothing);
      await tester.tap(find.byTooltip('关闭工作区'));
      await tester.pumpAndSettle();
      expect(find.byType(WorkspacePanel), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  previewTestWidgets(
    'message navigation appears on scroll, holds a fixed ring center, hides on input',
    (tester) async {
      tester.view.physicalSize = const Size(430, 932);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const SkiApp());
      await tester.pumpAndSettle();
      expect(find.byType(ChatPage), findsOneWidget);
      expect(
        find.byKey(const ValueKey('chat-message-navigation-ball')),
        findsNothing,
      );
      await tester.drag(find.byType(ListView).first, const Offset(0, -240));
      await tester.pump(const Duration(milliseconds: 100));
      final button = find.byKey(const ValueKey('chat-message-navigation-ball'));
      expect(button, findsOneWidget);
      final before = tester.getCenter(button);
      final hold = await tester.startGesture(before);
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump(const Duration(milliseconds: 200));
      final ring = find.byKey(const ValueKey('chat-message-dial-ring'));
      expect(ring, findsOneWidget);
      final ringCenter = tester.getCenter(ring);
      final preview = find.byKey(const ValueKey('chat-message-dial-target'));
      expect(
        tester.getBottomRight(preview).dy,
        lessThanOrEqualTo(tester.getTopLeft(ring).dy - 12),
      );
      await hold.moveBy(const Offset(-20, -30));
      await tester.pump();
      expect((tester.getCenter(ring) - ringCenter).distance, lessThan(1));
      await hold.up();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('chat-message-dial-ring')),
        findsNothing,
      );
      await tester.pump(const Duration(milliseconds: 1300));
      await tester.drag(find.byType(ListView).first, const Offset(0, -90));
      await tester.pump(const Duration(milliseconds: 100));
      if (button.evaluate().isNotEmpty) {
        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(find.text('消息定位'), findsOneWidget);
        Navigator.of(tester.element(find.text('消息定位'))).pop();
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byType(TextField).first);
      await tester.pump();
      expect(button, findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  test('unconfigured chat preserves input and never fabricates a reply', () {
    final store = DemoStore();
    expect(store.send('一个真实的问题'), isFalse);
    expect(store.messages, isEmpty);
    expect(store.streaming, isFalse);
    expect(store.lastError, contains('模型连接'));
    store.dispose();
  });
}

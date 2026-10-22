import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/main.dart';
import 'package:ski/chat.dart';
import 'package:ski/drawer_motion.dart';
import 'package:ski/workspace.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';

void main() {
  testWidgets('Android root route reached on system return shows chat', (
    tester,
  ) async {
    await tester.pumpWidget(const SkiApp());
    await tester.pumpAndSettle();
    final nav = Navigator.of(tester.element(find.byType(SkiShell)));
    nav.pushReplacementNamed('/');
    await tester.pumpAndSettle();
    expect(find.byType(ChatPage), findsOneWidget);
    expect(find.text('这里暂时没有页面'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'drawer glass covers system bars while controls retain safe insets',
    (tester) async {
      tester.view.physicalSize = const Size(500, 900);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(top: 36, bottom: 24);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const SkiApp());
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byType(SlideDeck)),
        const Rect.fromLTWH(0, 0, 500, 900),
      );
      expect(
        tester.getTopLeft(find.byTooltip('打开导航')).dy,
        greaterThanOrEqualTo(36),
      );
      final deck = tester.widget<SlideDeck>(find.byType(SlideDeck));
      for (final side in [1, -1]) {
        deck.motion.toggle(side);
        await tester.pumpAndSettle();
        final fill = find.byKey(const ValueKey('side-sheet-fill'));
        // The optical sheet reaches past the entire screen, including status and
        // navigation bars. Content alone keeps the original safe layout height.
        expect(tester.getTopLeft(fill).dy, lessThan(0));
        expect(tester.getTopRight(fill).dy, lessThan(0));
        expect(tester.getBottomLeft(fill).dy, greaterThan(900));
        expect(tester.getBottomRight(fill).dy, greaterThan(900));
        final content = side > 0
            ? find.byType(SideNavigation)
            : find.byType(WorkspacePanel);
        expect(tester.getSize(content).height, 840);
        if (side > 0) {
          expect(tester.getTopLeft(find.text('角色与陪伴')).dy, greaterThan(36));
        } else {
          expect(
            tester.getTopLeft(find.byTooltip('关闭工作区')).dy,
            greaterThan(36),
          );
        }
        deck.motion.close();
        await tester.pumpAndSettle();
      }
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Android glass keeps its material while dragging', (
    tester,
  ) async {
    await tester.pumpWidget(const SkiApp());
    await tester.pumpAndSettle();
    final drag = await tester.startGesture(const Offset(90, 300));
    await drag.moveBy(const Offset(150, 0));
    await tester.pump();
    final lenses = tester.widgetList<LiquidGlassLens>(
      find.byType(LiquidGlassLens),
    );
    expect(lenses, isNotEmpty);
    expect(lenses.every((lens) => !lens.style.liteGlass), isTrue);
    await drag.cancel();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });
  testWidgets('Android uses system safe area and full native width', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(500, 900);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 30, bottom: 24);
    addTearDown(tester.view.reset);
    const content = Key('native-content');
    await tester.pumpWidget(
      const MaterialApp(
        home: MobilePreviewStage(
          child: SafeArea(child: SizedBox.expand(key: content)),
        ),
      ),
    );
    expect(tester.getSize(find.byKey(content)), const Size(500, 846));
    expect(tester.getTopLeft(find.byKey(content)).dy, 30);
    expect(find.text('9:41'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

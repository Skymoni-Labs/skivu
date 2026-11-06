import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/glass.dart';
import 'package:ski/main.dart';
import 'package:ski/pages.dart';
import 'preview_fixture.dart';

void main() {
  setUp(seedPreviewConversation);

  testWidgets(
    'module pages scroll behind the shared glass toolbar with safe initial spacing',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(top: 30, bottom: 24);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const SkiApp());
      await tester.pumpAndSettle();

      for (final route in [
        '/settings',
        '/settings/appearance',
        '/settings/models',
        '/settings/permissions',
        '/characters',
        '/worlds',
        '/stickers',
        '/plugins',
        '/extensions',
        '/open-plugins',
      ]) {
        appNavigator.currentState!.pushReplacementNamed(route);
        await tester.pump();
        // Plugin/model pages may keep a remote-loading indicator animating.
        // Complete navigation without depending on their external data state.
        await tester.pump(const Duration(milliseconds: 400));
        final scroll = find
            .descendant(
              of: find.byType(ContentPage),
              matching: find.byType(SingleChildScrollView),
            )
            .first;
        final toolbar = find.byKey(const ValueKey('capsule-toolbar'));
        final viewport = tester.getRect(scroll);
        expect(
          viewport.top,
          0,
          reason: '$route fills the screen including behind the status bar',
        );
        expect(
          viewport.contains(tester.getCenter(toolbar)),
          isTrue,
          reason: '$route viewport includes the area behind the glass',
        );
        expect(
          viewport.bottom,
          844,
          reason: '$route also fills the bottom system gesture area',
        );
        final padding = tester
            .widget<SingleChildScrollView>(scroll)
            .padding!
            .resolve(TextDirection.ltr);
        expect(
          padding.bottom,
          40,
          reason: '$route last controls keep gesture clearance inside the list',
        );
        final content = find.byWidget(
          tester.widget<SingleChildScrollView>(scroll).child!,
        );
        expect(
          tester.getTopLeft(content).dy,
          greaterThan(tester.getBottomLeft(toolbar).dy + 8),
          reason: '$route first controls initially clear the toolbar',
        );
        final chrome = tester
            .widgetList<ConfigurableGlassSurface>(
              find.byType(ConfigurableGlassSurface),
            )
            .where((surface) => surface.area == 'toolbarBlur');
        expect(chrome.single.skymoni, isTrue);
        final state = tester.state<ScrollableState>(
          find.descendant(of: scroll, matching: find.byType(Scrollable)).first,
        );
        if (route == '/settings') {
          final firstEntry = find
              .descendant(
                of: find.byType(ContentPage),
                matching: find.byType(ListTile),
              )
              .first;
          final point = Offset(
            tester.getRect(toolbar).left + 56,
            tester.getCenter(toolbar).dy,
          );
          state.position.jumpTo(tester.getCenter(firstEntry).dy - point.dy);
          await tester.pump(const Duration(milliseconds: 100));
          expect(tester.getRect(firstEntry).contains(point), isTrue);
          await tester.tapAt(point);
          await tester.pump(const Duration(milliseconds: 400));
          expect(
            tester.widget<SkiShell>(find.byType(SkiShell)).route,
            route,
            reason: 'A tap on toolbar glass must not activate a hidden entry',
          );
        }
        if (state.position.maxScrollExtent > 100) {
          state.position.jumpTo(math.min(150, state.position.maxScrollExtent));
          await tester.pump(const Duration(milliseconds: 100));
          expect(
            tester.getTopLeft(content).dy,
            lessThan(tester.getCenter(toolbar).dy),
            reason: '$route content can travel behind the lens',
          );
        }
        expect(tester.takeException(), isNull, reason: route);
      }
      await tester.pumpWidget(const SizedBox());
    },
  );
}

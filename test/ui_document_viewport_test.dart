import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/ui_document_viewport.dart';

void main() {
  testWidgets('host bounds consume IME once and restore the navigation inset', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(412, 900);
    tester.view.devicePixelRatio = 1;
    tester.view.viewPadding = const FakeViewPadding(top: 32, bottom: 24);
    tester.view.padding = const FakeViewPadding(top: 32, bottom: 24);
    addTearDown(tester.view.reset);
    final sizes = <Size>[];
    const page = ValueKey('document');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SafeArea(
            top: false,
            child: UiDocumentViewport(
              onResize: sizes.add,
              child: const SizedBox.expand(key: page),
            ),
          ),
        ),
      ),
    );
    expect(sizes.last, const Size(412, 876));
    for (final ime in [280.0, 420.0, 315.0, 0.0, 390.0, 0.0]) {
      tester.view.viewInsets = FakeViewPadding(bottom: ime);
      tester.view.padding = FakeViewPadding(
        top: 32,
        bottom: ime == 0 ? 24 : 0,
      );
      await tester.pumpAndSettle();
      final bottom = ime == 0 ? 876.0 : 900 - ime;
      expect(sizes.last, Size(412, bottom));
      expect(tester.getBottomRight(find.byKey(page)).dy, bottom);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('rotation with IME open uses the remaining landscape viewport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(412, 900);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 350);
    addTearDown(tester.view.reset);
    final sizes = <Size>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UiDocumentViewport(
            onResize: sizes.add,
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
    expect(sizes.last, const Size(412, 550));
    tester.view.physicalSize = const Size(900, 412);
    tester.view.viewInsets = const FakeViewPadding(bottom: 180);
    await tester.pumpAndSettle();
    expect(sizes.last, const Size(900, 232));
    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pumpAndSettle();
    expect(sizes.last, const Size(900, 412));
    expect(tester.takeException(), isNull);
  });
}

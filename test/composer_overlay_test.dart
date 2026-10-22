import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/appearance.dart';
import 'package:ski/chat.dart';
import 'package:ski/chat_bubble_surface.dart';
import 'package:ski/state.dart';
import 'preview_fixture.dart';

void main() {
  setUp(seedPreviewConversation);
  testWidgets('reply paints through composer top gap without a dark strip', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final old = appearance.values;
    addTearDown(() {
      for (final entry in old.entries) appearance.set(entry.key, entry.value);
    });
    appearance.set('assistantOpacity', 1.0);
    appearance.set('customMessageColors', false);
    demo.messages
      ..clear()
      ..add(Message(false, List.filled(140, '用于观察输入框上沿的长回复。').join()));
    final capture = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: RepaintBoundary(
            key: capture,
            child: ChatPage(openWorkspace: () {}, openCall: () {}),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final composer = find.byKey(const ValueKey('chat-composer'));
    final top = tester.getTopLeft(composer).dy;
    expect(tester.getBottomRight(find.byType(ListView)).dy, greaterThan(top));
    expect(
      tester.getBottomRight(find.byType(ChatBubbleSurface)).dy,
      greaterThan(top + 6),
    );
    final bytes = await tester.runAsync(() async {
      final image =
          await (capture.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary)
              .toImage(pixelRatio: 1);
      try {
        return (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      } finally {
        image.dispose();
      }
    });
    // This used to be a black row where the message viewport was clipped.
    for (final y in [top.floor() - 2, top.floor() + 2]) {
      final red = bytes!.getUint8((y * 390 + 220) * 4);
      expect(red, greaterThan(220));
    }
    final controller = tester
        .widget<ListView>(find.byType(ListView))
        .controller!;
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('chat-composer-field')),
      'line1\nline2\nline3\nline4',
    );
    await tester.pumpAndSettle();
    expect(
      tester.getBottomRight(find.byType(ChatBubbleSurface)).dy,
      lessThan(tester.getTopLeft(composer).dy),
    );
    expect(controller.offset, closeTo(controller.position.maxScrollExtent, 1));
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    await tester.pumpAndSettle();
    expect(
      tester.getBottomRight(find.byType(ChatBubbleSurface)).dy,
      lessThan(tester.getTopLeft(composer).dy),
    );
    tester.view.viewInsets = const FakeViewPadding();
    appearance.set('showUsage', false);
    await tester.pumpAndSettle();
    expect(
      tester.getBottomRight(find.byType(ChatBubbleSurface)).dy,
      lessThan(tester.getTopLeft(composer).dy),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    demo.conversations[demo.conversation].draft = '';
  });
}

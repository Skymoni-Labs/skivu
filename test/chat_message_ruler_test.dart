import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/chat_message_dial.dart';
import 'package:ski/chat_message_dial_model.dart';

Widget host({
  required Future<List<ChatMessageLocatorPreview>> Function() load,
  required ValueChanged<int> jump,
  required VoidCallback open,
  int? Function()? resolve,
}) => MaterialApp(
  home: Scaffold(
    body: SizedBox(
      width: 320,
      height: 600,
      child: ChatMessageDial(
        visible: true,
        viewportHeight: 600,
        currentTimestamp: 1020,
        resolveCurrentTimestamp: resolve,
        loadEntries: load,
        onJump: jump,
        onOpenLocator: open,
        onHidden: () {},
        senderName: (_) => '角色',
      ),
    ),
  ),
);
List<ChatMessageLocatorPreview> entries() => List.generate(
  40,
  (i) => ChatMessageLocatorPreview(
    timestamp: 1000 + i,
    sender: 'assistant',
    previewContent: '第 $i 条历史内容',
    messageIndex: i,
  ),
);

void main() {
  testWidgets(
    'current message is resolved lazily only when the ruler is held',
    (tester) async {
      var resolutions = 0;
      await tester.pumpWidget(
        host(
          load: () async => entries(),
          jump: (_) {},
          open: () {},
          resolve: () {
            resolutions++;
            return 1030;
          },
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(resolutions, 0);
      final gesture = await tester.startGesture(
        tester.getCenter(
          find.byKey(const ValueKey('chat-message-navigation-ball')),
        ),
      );
      await tester.pump(const Duration(milliseconds: 650));
      await tester.pump();
      expect(resolutions, 1);
      expect(find.text('第 30 条历史内容'), findsOneWidget);
      await gesture.cancel();
      await tester.pumpWidget(const SizedBox());
    },
  );
  test('fine vertical navigation clamps without hidden overscroll', () {
    final ruler = MessageRuler(count: 100, index: 50);
    ruler.move(-90);
    expect(ruler.index, 40);
    ruler.move(9);
    expect(ruler.index, 41);
    ruler.move(-9000);
    expect(ruler.index, 0);
    ruler.move(9);
    expect(ruler.index, 1);
    ruler.advance(10000);
    expect(ruler.index, 99);
    ruler.move(-9);
    expect(ruler.index, 98);
  });
  test('moving left enables long-range browsing without a selection jump', () {
    final ruler = MessageRuler(count: 10000, index: 5000);
    ruler.move(0, leftwardDistance: 180);
    expect(ruler.index, 5000);
    ruler.move(-500, leftwardDistance: 180, extent: 500);
    expect(ruler.index, 0);
    ruler.move(500, leftwardDistance: 180, extent: 500);
    expect(ruler.index, 9999);
  });
  testWidgets('a short tap opens neither the ruler nor the old locator', (
    tester,
  ) async {
    var loads = 0, opens = 0;
    final jumps = <int>[];
    await tester.pumpWidget(
      host(
        load: () async {
          loads++;
          return entries();
        },
        jump: jumps.add,
        open: () => opens++,
      ),
    );
    await tester.tap(
      find.byKey(const ValueKey('chat-message-navigation-ball')),
    );
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.byKey(const ValueKey('chat-message-ruler')), findsNothing);
    expect(loads, 0);
    expect(opens, 0);
    expect(jumps, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'holding shows ticks and a preview, release jumps once and hides them',
    (tester) async {
      final jumps = <int>[];
      await tester.pumpWidget(
        host(load: () async => entries(), jump: jumps.add, open: () {}),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(
          find.byKey(const ValueKey('chat-message-navigation-ball')),
        ),
      );
      await tester.pump(const Duration(milliseconds: 650));
      await tester.pump();
      expect(find.byKey(const ValueKey('chat-message-ruler')), findsOneWidget);
      expect(find.text('第 20 条历史内容'), findsOneWidget);
      await gesture.moveBy(const Offset(0, -90));
      await tester.pump();
      expect(find.text('第 10 条历史内容'), findsOneWidget);
      expect(jumps, isEmpty);
      await gesture.up();
      await tester.pump();
      expect(jumps, [1010]);
      expect(find.byKey(const ValueKey('chat-message-ruler')), findsNothing);
      expect(
        find.byKey(const ValueKey('chat-message-ruler-target')),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('canceling a pending load never shows stale history or jumps', (
    tester,
  ) async {
    final pending = Completer<List<ChatMessageLocatorPreview>>();
    final jumps = <int>[];
    await tester.pumpWidget(
      host(load: () => pending.future, jump: jumps.add, open: () {}),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(
        find.byKey(const ValueKey('chat-message-navigation-ball')),
      ),
    );
    await tester.pump(const Duration(milliseconds: 650));
    expect(find.text('正在读取'), findsOneWidget);
    await gesture.cancel();
    pending.complete(entries());
    await tester.pump();
    expect(jumps, isEmpty);
    expect(find.byKey(const ValueKey('chat-message-ruler')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}

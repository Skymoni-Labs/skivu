import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ski/main.dart';
import 'package:ski/state.dart';
import 'package:ski/chat_message_dial.dart';
import 'package:ski/chat_bubble_surface.dart';

void main() {
  testWidgets(
    'large variable-height chat stays lazy and locates both directions',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(430, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final old = List<Conversation>.of(demo.conversations);
      final selected = demo.conversation;
      addTearDown(() {
        demo.conversations
          ..clear()
          ..addAll(old);
        demo.conversation = selected;
      });
      final chat = Conversation('长记录定位', [
        for (var i = 0; i < 320; i++)
          Message(
            i.isEven,
            '定位条目 $i\n${List.filled(i % 17 == 0 ? 35 : i % 4 + 1, '不同高度的聊天记录内容。').join('\n')}',
          ),
      ], personaId: demo.personas.first.id);
      demo.conversations
        ..clear()
        ..add(chat);
      demo.conversation = 0;
      await tester.pumpWidget(const SkiApp());
      await tester.pumpAndSettle();
      expect(find.byType(ChatBubbleSurface).evaluate().length, lessThan(35));
      Future<void> locate(int index) async {
        tester
            .widget<ChatMessageDial>(find.byType(ChatMessageDial))
            .onJump(index);
        for (var frame = 0; frame < 100; frame++) {
          await tester.pump(const Duration(milliseconds: 20));
        }
        final target = find.byKey(ValueKey('message-bubble-$index'));
        expect(target, findsOneWidget);
        final rect = tester.getRect(target);
        expect(rect.bottom, greaterThan(100));
        expect(rect.top, lessThan(750));
        expect(find.byType(ChatBubbleSurface).evaluate().length, lessThan(35));
      }

      await locate(241);
      await locate(13);
      await locate(238);
      await locate(0);
      tester.widget<ChatMessageDial>(find.byType(ChatMessageDial)).onLatest!();
      for (var frame = 0; frame < 100; frame++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(find.byKey(const ValueKey('message-bubble-319')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

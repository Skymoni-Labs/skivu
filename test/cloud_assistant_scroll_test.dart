import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/cloud_assistant.dart';

void main() {
  testWidgets(
    'assistant message text lets vertical touch and wheel scroll the surrounding conversation',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      await cloudAssistant.restore();
      final previous = cloudAssistant.messages.toList();
      cloudAssistant.messages
        ..clear()
        ..addAll(
          List.generate(
            20,
            (i) => {
              'role': 'assistant',
              'content':
                  'Message $i\nA long assistant receipt.\nRead the actual result.\nContinue scrolling.',
            },
          ),
        );
      final controller = ScrollController();
      addTearDown(() {
        cloudAssistant.messages
          ..clear()
          ..addAll(previous);
        controller.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              controller: controller,
              child: const CloudAssistantPane(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      controller.jumpTo(controller.position.maxScrollExtent / 2);
      await tester.pumpAndSettle();
      var text = find.byType(SelectableText).hitTestable().first;
      final beforeTouch = controller.offset;
      await tester.drag(text, const Offset(0, 150));
      await tester.pumpAndSettle();
      expect(
        controller.offset,
        lessThan(beforeTouch - 40),
        reason: 'Text must not trap vertical drags inside the message.',
      );
      controller.jumpTo(controller.position.maxScrollExtent / 2);
      await tester.pumpAndSettle();
      text = find.byType(SelectableText).hitTestable().first;
      final beforeWheel = controller.offset;
      await tester.sendEventToBinding(
        PointerScrollEvent(
          kind: PointerDeviceKind.mouse,
          position: tester.getCenter(text),
          scrollDelta: const Offset(0, -150),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        controller.offset,
        lessThan(beforeWheel - 40),
        reason: 'Wheel events over message text must reach the conversation.',
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );
}

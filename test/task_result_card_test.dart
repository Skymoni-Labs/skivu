import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/device_engine.dart';
import 'package:ski/state.dart';
import 'package:ski/task_result_card.dart';
import 'package:ski/tool_execution.dart';
import 'package:ski/tool_result_details.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ski/main.dart';
import 'package:ski/appearance.dart';
import 'package:ski/cloud_conversations.dart';
import 'package:ski/thinking_disclosure.dart';
import 'preview_fixture.dart';

Message result(
  String outcome, {
  String tool = 'clock.timer.start',
  String? verification,
}) {
  final fields = <String, dynamic>{
    'taskId': 'task',
    'requestId': 'one',
    'tool': tool,
    'purpose': '设置10分钟倒计时',
    'outcome': outcome,
    if (verification != null) 'verification': verification,
    ...toolResultDetails(tool, {'seconds': 600}, {}),
  };
  return Message(false, '$tool · $outcome\n真实回执')
    ..toolReceipt = true
    ..toolExecution = ToolExecutionEvent.parse(jsonDecode(jsonEncode(fields)));
}

void main() {
  testWidgets(
    'thinking stays above the reply and the completion card stays below it',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      seedPreviewConversation();
      demo.streaming = false;
      appearance.set('reduceMotion', true);
      appearance.set('showThinking', true);
      demo.openCloudChat();
      final chat = demo.conversations[demo.conversation];
      final receipt = result('verified')
        ..turnId = 'turn'
        ..authorId = cloudPersonaId;
      chat.messages
        ..clear()
        ..addAll([
          Message(true, '设置10分钟倒计时')..turnId = 'turn',
          receipt,
          Message(false, '任务完成回复')
            ..thinking = '服务返回的思考内容'
            ..turnId = 'turn'
            ..authorId = cloudPersonaId,
        ]);
      final engine = cloudChats.engineFor(chat);
      engine.account = cloudChats.identity();
      engine.taskId = 'task';
      engine.phase = 'done';
      await tester.pumpWidget(const SkiApp());
      await tester.pumpAndSettle();
      expect(find.byType(ThinkingDisclosure), findsOneWidget);
      expect(find.byType(TaskResultCard), findsOneWidget);
      expect(
        tester.getTopLeft(find.byType(ThinkingDisclosure)).dy,
        lessThan(tester.getTopLeft(find.text('任务完成回复')).dy),
      );
      expect(
        tester.getTopLeft(find.byType(TaskResultCard)).dy,
        greaterThan(tester.getBottomLeft(find.text('任务完成回复')).dy),
      );
      final avatar = find.byKey(ValueKey('execution-avatar-${receipt.id}'));
      final before = tester.getTopLeft(avatar);
      await tester.tap(find.byKey(const ValueKey('thinking-toggle')));
      await tester.pumpAndSettle();
      expect(find.text('服务返回的思考内容'), findsOneWidget);
      expect(tester.getTopLeft(avatar), before);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  test(
    'dispatch, unknown, failed and process exit never create a success card',
    () {
      for (final outcome in [
        'dispatched',
        'unknown',
        'failed',
        'permission_required',
        'cancelled',
      ]) {
        expect(TaskResult.fromMessages([result(outcome)]), isNull);
      }
      expect(
        TaskResult.fromMessages([
          result(
            'verified',
            tool: 'shell.execute',
            verification: 'process_exit',
          ),
        ]),
        isNull,
      );
      expect(
        TaskResult.fromMessages([result('verified')], phase: 'thinking'),
        isNull,
      );
      expect(
        TaskResult.fromMessages([result('verified')], phase: 'failed'),
        isNull,
      );
      expect(
        TaskResult.fromMessages([
          result('verified', tool: 'assistant.alarm.create'),
        ]),
        isNull,
      );
    },
  );
  test(
    'native verification and user confirmation retain distinct labels after export',
    () {
      final verified = TaskResult.fromMessages([result('verified')])!;
      expect(verified.title, '10分钟倒计时');
      expect(verified.target, 'clock.timers');
      expect(verified.status, '已完成');
      expect(
        TaskResult.fromMessages([result('user_confirmed')])!.status,
        '你已确认完成',
      );
    },
  );
  testWidgets(
    'card fits narrow enlarged text and only explicit Open navigates without replay',
    (tester) async {
      final calls = <String>[];
      final engine = DeviceEngine(
        transport: (method, args) async {
          calls.add('$method:${args['target']}');
          return {'opened': true};
        },
      );
      final data = TaskResult.fromMessages([result('verified')])!;
      for (final brightness in Brightness.values) {
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: brightness),
            home: Scaffold(
              body: MediaQuery(
                data: const MediaQueryData(textScaler: TextScaler.linear(1.6)),
                child: SizedBox(
                  width: 280,
                  child: TaskResultCard(
                    result: data,
                    onOpen: () => engine.openResult(data.target!),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
      }
      expect(calls, isEmpty);
      await tester.tap(find.text('打开'));
      expect(calls, ['result.open:clock.timers']);
      expect(
        () => engine.openResult('intent://replay-alarm'),
        throwsFormatException,
      );
    },
  );
}

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ski/appearance.dart';
import 'package:ski/chat_bubble_surface.dart';
import 'package:ski/chat_message_dial.dart';
import 'package:ski/cloud_conversations.dart';
import 'package:ski/cloud_execution_disclosure.dart';
import 'package:ski/main.dart';
import 'package:ski/state.dart';
import 'package:ski/tool_execution.dart';
import 'preview_fixture.dart';

Message toolRecord(
  String request, {
  String task = 'qa-task',
  String turn = 'qa-turn',
  String purpose = '读取当前亮度',
  String? outcome,
  String summary = '当前亮度为 80。',
}) =>
    Message(
        false,
        outcome == null
            ? '$purpose · settings.brightness.read'
            : 'settings.brightness.read · $outcome\n$summary',
      )
      ..turnId = turn
      ..authorId = cloudPersonaId
      ..toolReceipt = true
      ..toolExecution = ToolExecutionEvent(
        taskId: task,
        requestId: request,
        tool: 'settings.brightness.read',
        purpose: purpose,
        outcome: outcome,
      );

List<Message> completedRound() => [
  Message(true, '请检查手机状态。')..turnId = 'qa-turn',
  toolRecord('read'),
  toolRecord('read', outcome: 'verified'),
  toolRecord('check', purpose: '核对执行结果'),
  toolRecord(
    'check',
    purpose: '核对执行结果',
    outcome: 'verified',
    summary: '核对完毕，没有修改系统设置。',
  ),
  Message(false, '已检查，手机状态正常。')
    ..turnId = 'qa-turn'
    ..authorId = cloudPersonaId,
];

void main() {
  test(
    'two tool calls become one view row without rewriting the transcript',
    () {
      final messages = completedRound();
      final before = jsonEncode(messages.map((m) => m.toJson()).toList());
      final rows = cloudTranscriptRows(messages, cloud: true);
      expect(rows, hasLength(3));
      expect(rows[1].messages, hasLength(4));
      expect(rows.last.first, same(messages.last));
      final steps = cloudExecutionSteps(rows[1].messages);
      expect(steps, hasLength(2));
      expect(steps.map((s) => s.outcome), ['verified', 'verified']);
      expect(jsonEncode(messages.map((m) => m.toJson()).toList()), before);
      expect(cloudTranscriptRows(messages, cloud: false), hasLength(6));
    },
  );

  test('turn and task boundaries keep independent execution groups', () {
    final messages = [
      toolRecord('one'),
      toolRecord('two', task: 'other-task'),
      toolRecord('three', task: 'other-task', turn: 'other-turn'),
      Message(false, '单独的答复'),
      toolRecord('four', task: 'other-task', turn: 'other-turn'),
    ];
    expect(cloudTranscriptRows(messages, cloud: true), hasLength(5));
  });

  test('permission continuation updates one step and survives chat export', () {
    final messages = [
      toolRecord('one'),
      toolRecord('one', outcome: 'permission_required'),
      toolRecord('one', outcome: 'verified'),
    ];
    final restored = messages
        .map((m) => Message.fromJson(jsonDecode(jsonEncode(m.toJson()))))
        .toList();
    final steps = cloudExecutionSteps(restored);
    expect(steps, hasLength(1));
    expect(steps.single.outcome, 'verified');
    expect(steps.single.purpose, '读取当前亮度');
    expect(restored.first.apiMessage['role'], 'user');
    expect(restored.first.apiMessage['content'], startsWith('工具回执（历史数据）'));
    expect(restored.first.apiMessage.containsKey('toolExecution'), false);
  });

  test(
    'legacy history is retained without inventing request IDs or success',
    () {
      final legacy = Message(false, '旧版原始工具回执')..toolReceipt = true;
      final raw = legacy.toJson()..remove('toolExecution');
      final restored = Message.fromJson(raw);
      expect(restored.toolExecution, isNull);
      final step = cloudExecutionSteps([restored]).single;
      expect(step.legacy, true);
      expect(step.summary, '旧版原始工具回执');
      expect(step.outcome, isNull);
      expect(
        ToolExecutionEvent.parse({'tool': 'brightness', 'requestId': 7}),
        isNull,
      );
    },
  );

  testWidgets('Cloud groups tool bubbles and toggling never runs a task', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    seedPreviewConversation();
    demo.streaming = false;
    appearance.set('reduceMotion', true);
    demo.openCloudChat();
    final chat = demo.conversations[demo.conversation];
    chat.messages
      ..clear()
      ..addAll(completedRound());
    final engine = cloudChats.engineFor(chat);
    engine.account = cloudChats.identity();
    engine.taskId = 'qa-task';
    engine.phase = 'done';
    final epoch = engine.epoch;
    final archive = jsonEncode(chat.messages.map((m) => m.toJson()).toList());
    await tester.pumpWidget(const SkiApp());
    await tester.pumpAndSettle();
    expect(find.byType(CloudExecutionDisclosure), findsOneWidget);
    expect(find.text('执行过程 · 已完成 · 2 个步骤'), findsOneWidget);
    expect(find.byType(ChatBubbleSurface), findsNWidgets(2));
    expect(find.text('当前亮度为 80。'), findsNothing);
    expect(find.text('已检查，手机状态正常。'), findsOneWidget);
    final toggle = find.byKey(
      ValueKey('execution-toggle-${chat.messages[1].id}'),
    );
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.text('1. 读取当前亮度'), findsOneWidget);
    expect(find.text('2. 核对执行结果'), findsOneWidget);
    expect(find.text('当前亮度为 80。'), findsOneWidget);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.text('当前亮度为 80。'), findsNothing);
    expect(engine.epoch, epoch);
    expect(engine.phase, 'done');
    expect(jsonEncode(chat.messages.map((m) => m.toJson()).toList()), archive);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'live progress stays folded and permission controls stay visible',
    (tester) async {
      var expanded = false, resumed = 0, opened = 0;
      var phase = 'executing';
      final messages = [toolRecord('one')];
      late StateSetter redraw;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                redraw = setState;
                return CloudExecutionDisclosure(
                  messages: messages,
                  phase: phase,
                  pendingRequestId: 'one',
                  expanded: expanded,
                  onToggle: () => redraw(() => expanded = !expanded),
                  onResume: () => resumed++,
                  onCapabilities: () => opened++,
                );
              },
            ),
          ),
        ),
      );
      expect(find.text('执行过程 · 正在执行 · 1 个步骤'), findsOneWidget);
      expect(find.text('读取当前亮度'), findsOneWidget);
      redraw(() {
        messages.add(
          toolRecord('one', outcome: 'permission_required', summary: '需要系统授权。'),
        );
        phase = 'permission';
      });
      await tester.pump();
      expect(find.text('需要系统授权。'), findsOneWidget);
      expect(find.text('查看授权'), findsOneWidget);
      expect(find.text('核对授权并继续'), findsOneWidget);
      expect(expanded, false);
      expect(resumed, 0);
      await tester.tap(find.text('查看授权'));
      expect(opened, 1);
      await tester.tap(find.text('核对授权并继续'));
      expect(resumed, 1);
      redraw(() {
        messages.add(toolRecord('one', outcome: 'verified'));
        phase = 'done';
      });
      await tester.pump();
      expect(find.text('执行过程 · 已完成 · 1 个步骤'), findsOneWidget);
      expect(find.text('查看授权'), findsNothing);
      expect(find.text('当前亮度为 80。'), findsNothing);
      expect(expanded, false);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failures, uncertain results and dispatch are visible when folded',
    (tester) async {
      for (final outcome in ['failed', 'unknown', 'dispatched']) {
        final messages = [
          toolRecord('one'),
          toolRecord('one', outcome: outcome, summary: '这一步没有完成。'),
        ];
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: CloudExecutionDisclosure(
                messages: messages,
                phase: outcome == 'unknown' ? 'unknown' : 'done',
                expanded: false,
                onToggle: () {},
              ),
            ),
          ),
        );
        await tester.pump();
        expect(
          find.byKey(ValueKey('execution-alert-${messages.first.id}')),
          findsOneWidget,
        );
        expect(find.textContaining('已完成'), findsNothing, reason: outcome);
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets(
    'history navigation locates records inside folded long tool runs',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      seedPreviewConversation();
      demo.streaming = false;
      appearance.set('reduceMotion', true);
      demo.openCloudChat();
      final chat = demo.conversations[demo.conversation];
      chat.messages.clear();
      for (var turn = 0; turn < 24; turn++) {
        chat.messages.add(Message(true, '第 $turn 轮检查')..turnId = 'turn-$turn');
        for (var step = 0; step < 8; step++) {
          chat.messages.addAll([
            toolRecord(
              '$turn-$step',
              task: 'task-$turn',
              turn: 'turn-$turn',
              purpose: '第 $turn 轮步骤 $step',
            ),
            toolRecord(
              '$turn-$step',
              task: 'task-$turn',
              turn: 'turn-$turn',
              purpose: '第 $turn 轮步骤 $step',
              outcome: 'verified',
            ),
          ]);
        }
        chat.messages.add(
          Message(false, '第 $turn 轮已完成')..turnId = 'turn-$turn',
        );
      }
      await tester.pumpWidget(const SkiApp());
      await tester.pumpAndSettle();
      for (final turn in [20, 2, 17]) {
        final index = chat.messages.indexWhere(
          (m) => m.toolExecution?.requestId == '$turn-6',
        );
        tester
            .widget<ChatMessageDial>(find.byType(ChatMessageDial))
            .onJump(index);
        for (var frame = 0; frame < 90; frame++) {
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(find.text('7. 第 $turn 轮步骤 6'), findsOneWidget);
        expect(
          find.byType(CloudExecutionDisclosure).evaluate().length,
          lessThan(10),
        );
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('expanded history fits narrow screens and large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(1.6)),
          child: child!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(55, 16, 16, 16),
              child: CloudExecutionDisclosure(
                messages: completedRound().where((m) => m.toolReceipt).toList(),
                expanded: true,
                onToggle: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('2. 核对执行结果'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

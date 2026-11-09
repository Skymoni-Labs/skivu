import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ski/main.dart' as app;
import 'package:ski/state.dart';
import 'package:ski/model_connection.dart';
import 'package:ski/device_engine.dart';
import 'package:ski/personal_space.dart';
import 'package:ski/task_result_card.dart';
import 'package:ski/tool_execution.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'cloud and task pages edit the same durable records without external effects',
    (tester) async {
      expect(const bool.fromEnvironment('SKIVU_ENGINE_QA'), true);
      await app.main();
      for (var i = 0; i < 16; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      final oldConnection = demo.models.activeId;
      final oldAccount = demo.useAccount, oldBeta = demo.useBeta;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var external = 0, lookups = 0, requests = 0;
      var bindingPresent = false;
      messenger.setMockMethodCallHandler(DeviceEngine.channel, (call) async {
        switch (call.method) {
          case 'status':
            return {'enabled': false};
          case 'session.start':
          case 'session.end':
            return {};
          case 'cancelRequest':
            return {'outcome': 'cancelled'};
          case 'effect.lookup':
            lookups++;
            return {'found': false};
          case 'invoke':
          case 'result.open':
            external++;
            throw StateError('no external dispatch allowed');
          default:
            throw StateError('Unexpected platform call ${call.method}');
        }
      });
      final day = personalDay(DateTime.now().add(const Duration(days: 1)));
      const title = '整理旅行清单';
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        requests++;
        final task = personalSpace.tasks
            .where((r) => r.title == title)
            .firstOrNull;
        Map<String, dynamic> response;
        if (requests == 1) {
          response = {
            'type': 'call',
            'tool': 'tasks.create',
            'arguments': {'title': title, 'date': day, 'body': '证件、充电器、衣物'},
            'message': '记录明天的待办',
          };
        } else if (requests == 3) {
          bindingPresent =
              jsonEncode(body).contains('用户本条消息选中的任务') &&
              jsonEncode(body).contains(task!.id);
          response = {
            'type': 'call',
            'tool': 'tasks.get',
            'arguments': {'id': task!.id},
            'message': '读取所选任务的最新状态',
          };
        } else if (requests == 4) {
          response = {
            'type': 'call',
            'tool': 'tasks.update',
            'arguments': {
              'id': task!.id,
              'expectedRevision': task.revision,
              'time': '10:30',
            },
            'message': '把任务安排到10:30',
          };
        } else {
          response = {
            'type': 'final',
            'message': requests == 2
                ? '已记下明天整理旅行清单，尚未启用提醒。'
                : requests == 5
                ? '已改为明天10:30，任务页同步更新。'
                : '好的，随时继续聊。',
          };
        }
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'choices': [
              {
                'message': {'content': jsonEncode(response)},
              },
            ],
          }),
        );
        await request.response.close();
      });
      final connection = ModelConnection(
        id: 'managed-tasks-local-qa',
        name: '本地任务联动验收',
        provider: '本地验收',
        protocol: ApiProtocol.chat,
        address: 'http://127.0.0.1:${server.port}/v1',
        model: 'local-managed-task',
        auth: 'none',
        streaming: false,
      );
      Future<void> poll(bool Function() check) async {
        for (var i = 0; i < 240 && !check(); i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
          await tester.pump(const Duration(milliseconds: 100));
        }
        if (!check())
          debugPrint(
            'TASKS_DIAGNOSTIC requests=$requests messages=${jsonEncode(demo.messages.map((m) => m.toJson()).toList())}',
          );
        expect(check(), true);
        await tester.pump(const Duration(milliseconds: 500));
      }

      Future<void> frame(String name) async {
        debugPrint('MANAGED_TASKS_FRAME $name');
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(seconds: 2)),
        );
      }

      Future<void> send(String text) async {
        final field = tester.widget<TextField>(
          find.byKey(const ValueKey('chat-composer-field')),
        );
        field.controller!.text = text;
        field.onSubmitted!(text);
        await tester.pump(const Duration(milliseconds: 200));
        await poll(() => !demo.streaming);
      }

      try {
        demo.models.connections.add(connection);
        demo.models.activeId = connection.id;
        demo.useAccount = false;
        demo.useBeta = false;
        demo.newChat(personaId: cloudPersonaId);
        await tester.pump(const Duration(milliseconds: 500));
        await send('帮我记一下明天整理旅行清单');
        expect(requests, 2);
        final task = personalSpace.tasks.singleWhere((r) => r.title == title);
        final originalId = task.id;
        expect(find.byType(TaskResultCard), findsOneWidget);
        expect(find.text('查看任务'), findsOneWidget);
        expect(find.textContaining('待办已保存'), findsOneWidget);
        await frame('created');
        await tester.ensureVisible(find.text('我的任务'));
        await tester.tap(find.text('我的任务'));
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(Checkbox), findsOneWidget);
        await tester.tap(find.byType(Checkbox));
        await poll(() => personalSpace.task(originalId)!.done);
        await frame('task-list');
        await tester.tap(find.byTooltip('交给小云'));
        await tester.pump(const Duration(milliseconds: 400));
        expect(
          find.byKey(const ValueKey('cloud-selected-task')),
          findsOneWidget,
        );
        await send('把这条任务安排到明天10:30');
        expect(bindingPresent, true);
        expect(personalSpace.task(originalId)!.time, '10:30');
        expect(personalSpace.task(originalId)!.done, true);
        expect(
          personalSpace.tasks.where((r) => r.title == title),
          hasLength(1),
        );
        expect(find.byKey(const ValueKey('cloud-selected-task')), findsNothing);
        await frame('updated');
        // A controlled external-result fixture tests saving metadata, never a clock mutation.
        final chat = demo.conversations[demo.conversation];
        chat.messages.addAll([
          Message(true, '受控验收结果卡片')..turnId = 'external-fixture',
          Message(false, '受控验收回执')
            ..authorId = cloudPersonaId
            ..turnId = 'external-fixture'
            ..toolReceipt = true
            ..toolExecution = const ToolExecutionEvent(
              taskId: 'fixture',
              requestId: 'clock-fixture',
              tool: 'clock.alarm.create',
              purpose: '受控闹钟结果',
              outcome: 'verified',
              effect: 'write',
              resultTitle: '8点起床',
              resultDetail: '08:00 · 手机时钟',
              resultTarget: 'clock.alarms',
            ),
          Message(false, '下面是用于验收加入任务的结果卡片。')
            ..authorId = cloudPersonaId
            ..turnId = 'external-fixture',
        ]);
        demo.changed();
        await tester.pump(const Duration(milliseconds: 700));
        await tester.pump(const Duration(milliseconds: 600));
        final transcript = tester
            .widget<ListView>(find.byType(ListView).first)
            .controller!;
        transcript.jumpTo(transcript.position.maxScrollExtent);
        await tester.pump(const Duration(milliseconds: 600));
        await Scrollable.ensureVisible(
          tester.element(find.text('加入任务')),
          alignment: .5,
        );
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.text('加入任务'));
        await poll(() => personalSpace.tasks.any((r) => r.title == '8点起床'));
        final saved = personalSpace.tasks.singleWhere((r) => r.title == '8点起床');
        expect(saved.done, true);
        expect(saved.sourceTarget, 'clock.alarms');
        expect(saved.date, '');
        expect(external, 0);
        expect(lookups, 0);
        await frame('attached');
        await send('好的，随便聊聊');
        expect(requests, 6);
        expect(personalSpace.tasks, hasLength(2));
        final restored = PersonalSpaceStore();
        await restored.restore();
        expect(restored.task(originalId)!.time, '10:30');
        expect(restored.task(saved.id)!.sourceTarget, 'clock.alarms');
        expect(tester.takeException(), isNull);
        binding.reportData = {
          'passed': true,
          'realAndroidUi': true,
          'sharedRecords': true,
          'manualComplete': true,
          'selectedTaskBinding': bindingPresent,
          'datedTaskNotScheduled': true,
          'resultSavedAsCompleted': true,
          'restoredFromDisk': true,
          'externalDispatches': external,
          'nativeEffectLookups': lookups,
          'localModelRequests': requests,
          'paidModelCalls': 0,
          'phoneTargeted': false,
        };
      } finally {
        if (demo.streaming) demo.stop();
        messenger.setMockMethodCallHandler(DeviceEngine.channel, null);
        demo.models.connections.removeWhere((c) => c.id == connection.id);
        demo.models.activeId = oldConnection;
        demo.useAccount = oldAccount;
        demo.useBeta = oldBeta;
        demo.changed();
        await demo.saveChats();
        await server.close(force: true);
      }
    },
  );
}

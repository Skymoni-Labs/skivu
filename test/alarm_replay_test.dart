import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/tool_submission.dart';
import 'package:ski/assistant_engine.dart';
import 'package:ski/cloud_execution_disclosure.dart';
import 'package:ski/device_engine.dart';
import 'package:ski/state.dart';
import 'cloud_conversations_test.dart' show bind;
import 'real_chat_store_test.dart' show MemoryChats, TestModels, waitForReply;
import 'cloud_execution_test.dart' show toolRecord;

const alarm =
    '{"type":"call","tool":"clock.alarm.create","arguments":{"hour":7,"minute":15},"message":"设置7点15分闹钟"}';
const hello = '{"type":"final","message":"我们聊新的话题。"}';

class FixtureTools implements AssistantExtensions {
  FixtureTools(this.effect);
  final String effect;
  int calls = 0;
  @override
  Future<List<Map<String, dynamic>>> catalog() async => [
    {
      'id': 'plugin:qa/work',
      'effect': effect,
      'available': true,
      'parameters': {
        'type': 'object',
        'properties': {},
        'required': [],
        'additionalProperties': false,
      },
    },
  ];
  @override
  Future<DeviceToolReceipt> invoke(
    String tool,
    Map<String, dynamic> args,
    String requestId,
    void Function() check,
  ) async {
    check();
    calls++;
    return DeviceToolReceipt({
      'requestId': requestId,
      'outcome': effect == 'read' ? 'verified' : 'dispatched',
      'summary': 'fixture',
    });
  }

  @override
  Future<Map<String, dynamic>> cancel() async => {'outcome': 'cancelled'};
}

void main() {
  test('navigation remains repeatable for observing and verifying effects', () {
    for (final tool in [
      'apps.launch',
      'settings.open',
      'clock.alarms.show',
      'ui.back',
      'ui.home',
      'ui.scroll',
    ]) {
      expect(ToolSubmission.fingerprintFor(tool, {}), isNull);
    }
  });
  for (final nativeHistory in [false, true]) {
    test(
      'stopping during effect-fence storage (native history: $nativeHistory) cannot resurrect or dispatch the task',
      () async {
        final storageStarted = Completer<void>();
        final release = Completer<void>();
        var effects = 0;
        final a = AssistantEngine(
          identity: () => 'qa',
          read: () async => null,
          write: (_) async {},
          findPreviousEffect: nativeHistory
              ? (_, __) async => {'found': true, 'outcome': 'dispatched'}
              : null,
          persistToolSubmissions: () async {
            storageStarted.complete();
            await release.future;
          },
          model: (_, __) async => alarm,
          engine: DeviceEngine(
            transport: (method, args) async {
              if (method == 'status') return {'enabled': true, 'system': true};
              if (args['tool'] == 'device.receipt')
                return {
                  'requestId': args['requestId'],
                  'outcome': 'verified',
                  'value': {'found': true, 'outcome': 'dispatched'},
                };
              if (method == 'cancelRequest') return {'outcome': 'cancelled'};
              effects++;
              return {
                'requestId': args['requestId'],
                'outcome': 'dispatched',
                'summary': 'late',
              };
            },
          ),
        );
        final run = a.send('设置闹钟');
        await storageStarted.future;
        await a.stop();
        release.complete();
        await run;
        expect(effects, 0);
        expect(a.phase, 'stopped');
        expect(a.toolSubmissions.single.protected, true);
      },
    );
  }
  for (final entry in {
    'clock.timer.start': {'seconds': 20},
    'ui.tap': {'observationId': 'qa-view', 'elementId': 'qa-control'},
    'settings.brightness.write': {'level': 80},
    'shell.execute': {'command': 'fixture-only'},
  }.entries) {
    test(
      'generic effect fence prevents a stale ${entry.key} plan in the next turn',
      () async {
        var calls = 0, plans = 0;
        final command = jsonEncode({
          'type': 'call',
          'tool': entry.key,
          'arguments': entry.value,
          'message': 'fixture operation',
        });
        final a = AssistantEngine(
          identity: () => 'qa',
          read: () async => null,
          write: (_) async {},
          model: (_, __) async => ++plans == 2 ? hello : command,
          engine: DeviceEngine(
            transport: (method, args) async {
              if (method == 'status') return {'enabled': true, 'system': true};
              if (args['tool'] == 'device.receipt')
                return {
                  'requestId': args['requestId'],
                  'outcome': 'verified',
                  'value': {'found': true, 'outcome': 'dispatched'},
                };
              calls++;
              return {
                'requestId': args['requestId'],
                'outcome': 'dispatched',
                'summary': '已提交',
              };
            },
          ),
        );
        await a.send('完成本次操作');
        expect(a.phase, 'awaiting_verification');
        expect(a.messages.last['content'], isNot(contains('没有成功')));
        await a.send('聊一点别的');
        expect(a.phase, 'awaiting_verification');
        expect(calls, 1);
        expect(a.pending, isNull);
        expect(a.hasUnverifiedEffects, true);
      },
    );
  }

  test(
    'plugin writes share the fence while read-only tools remain repeatable',
    () async {
      for (final effect in ['external', 'read']) {
        final tools = FixtureTools(effect);
        var plans = 0;
        const command =
            '{"type":"call","tool":"plugin:qa/work","arguments":{},"message":"plugin fixture"}';
        final a = AssistantEngine(
          identity: () => 'qa',
          extensions: tools,
          read: () async => null,
          write: (_) async {},
          engine: DeviceEngine(transport: (_, __) async => {'enabled': true}),
          model: (_, __) async => (++plans).isOdd ? command : hello,
        );
        await a.send('第一次');
        await a.send('第二次');
        expect(tools.calls, effect == 'read' ? 2 : 1);
        expect(a.phase, effect == 'read' ? 'done' : 'awaiting_verification');
      }
    },
  );

  test(
    'process exit cannot be promoted to verified business completion',
    () async {
      var plans = 0;
      final a = AssistantEngine(
        identity: () => 'qa',
        read: () async => null,
        write: (_) async {},
        model: (_, __) async => ++plans == 1
            ? '{"type":"call","tool":"shell.execute","arguments":{"command":"fixture-only"},"message":"run"}'
            : hello,
        engine: DeviceEngine(
          transport: (method, args) async => method == 'status'
              ? {'enabled': true}
              : {
                  'requestId': args['requestId'],
                  'outcome': 'verified',
                  'summary': 'process ended',
                  'value': {
                    'verification': 'process_exit',
                    'businessVerified': false,
                  },
                },
        ),
      );
      await a.send('完成目标');
      expect(a.phase, 'awaiting_verification');
      expect(a.toolSubmissions.single.outcome, 'dispatched');
      expect(a.canConfirmResult, true);
    },
  );

  test(
    'a durable prepared effect survives interruption before its receipt',
    () async {
      final pending = Completer<Map<String, dynamic>>();
      final started = Completer<void>();
      String? disk;
      String requestId = '';
      var calls = 0;
      final device = DeviceEngine(
        transport: (method, args) async {
          if (method == 'status') return {'enabled': true};
          if (args['tool'] == 'device.receipt')
            return {
              'requestId': args['requestId'],
              'outcome': 'verified',
              'value': {'found': true, 'outcome': 'dispatched'},
            };
          if (method == 'cancelRequest') return {'outcome': 'cancelled'};
          calls++;
          requestId = args['requestId'] as String;
          started.complete();
          return pending.future;
        },
      );
      const command =
          '{"type":"call","tool":"settings.brightness.write","arguments":{"level":45},"message":"change"}';
      final a = AssistantEngine(
        identity: () => 'qa',
        engine: device,
        read: () async => null,
        write: (raw) async => disk = raw,
        model: (_, __) async => command,
      );
      final run = a.send('打开软件');
      await started.future;
      final interrupted = disk;
      expect(jsonDecode(interrupted!)['toolSubmissions'], hasLength(1));
      await a.stop();
      pending.complete({
        'requestId': requestId,
        'outcome': 'dispatched',
        'summary': 'late',
      });
      await run;
      final b = AssistantEngine(
        identity: () => 'qa',
        engine: device,
        read: () async => interrupted,
        write: (_) async {},
        model: (_, __) async => command,
      );
      await b.send('我们聊别的');
      expect(calls, 1);
      expect(b.phase, 'awaiting_verification');
    },
  );
  test(
    'dispatch permits read-only verification and user confirmation is separate evidence',
    () async {
      var plans = 0, writes = 0;
      final a = AssistantEngine(
        identity: () => 'qa',
        read: () async => null,
        write: (_) async {},
        model: (_, __) async {
          plans++;
          return alarm;
        },
        engine: DeviceEngine(
          transport: (method, args) async {
            if (method == 'status') return {'enabled': true, 'system': true};
            if (args['tool'] == 'device.receipt')
              return {
                'requestId': args['requestId'],
                'outcome': 'verified',
                'value': {'found': true, 'outcome': 'dispatched'},
              };
            writes++;
            return {
              'requestId': args['requestId'],
              'outcome': 'dispatched',
              'summary': '交给时钟',
            };
          },
        ),
      );
      await a.send('设置7点15分闹钟');
      expect(
        plans,
        3,
        reason:
            'Original dispatch, read-only receipt recovery, then no-progress stop',
      );
      expect(writes, 1);
      expect(a.phase, 'awaiting_verification');
      expect(a.pending, isNull);
      expect(a.messages.last['content'], contains('原回执仍不能确认业务完成'));
      expect(a.canConfirmResult, true);
      await a.confirmResult();
      expect(a.phase, 'done');
      expect(a.toolSubmissions.single.outcome, 'user_confirmed');
      expect(a.messages.last['content'], contains('按你的确认'));
      expect(
        writes,
        1,
        reason: 'Confirming observed success cannot set an alarm',
      );
    },
  );

  test(
    'same alarm across turns and restarts reads the original result without repeating',
    () async {
      var writes = 0;
      String? disk;
      final ids = <String>[];
      DeviceEngine device() => DeviceEngine(
        transport: (method, args) async {
          if (method == 'status') return {'enabled': true, 'system': true};
          if (args['tool'] == 'device.receipt')
            return {
              'requestId': args['requestId'],
              'outcome': 'verified',
              'value': {'found': true, 'outcome': 'dispatched'},
            };
          writes++;
          ids.add(args['requestId'] as String);
          return {
            'requestId': args['requestId'],
            'outcome': 'dispatched',
            'summary': '提交成功',
          };
        },
      );
      AssistantEngine create() => AssistantEngine(
        identity: () => 'qa',
        engine: device(),
        model: (_, __) async => alarm,
        read: () async => disk,
        write: (value) async => disk = value,
      );
      final a = create();
      await a.send('设置闹钟');
      final b = create();
      await b.send('我们聊点别的');
      expect(b.phase, 'awaiting_verification');
      expect(
        writes,
        1,
        reason: 'Even a stale model plan cannot repeat the alarm',
      );
      expect(b.messages.last['content'], contains('相同操作未重复执行'));
      await b.resume();
      expect(writes, 1);
      expect(ids.toSet(), hasLength(1));
      await b.confirmResult();
      expect(writes, 1);
      expect(b.phase, 'done');
    },
  );

  test(
    'a new topic discards old permission/confirmation pending without replay',
    () async {
      var writes = 0, round = 0;
      final a = AssistantEngine(
        identity: () => 'qa',
        read: () async => null,
        write: (_) async {},
        model: (_, history) async {
          if (++round == 1) return alarm;
          if (round == 2) return hello;
          expect(history.last['content'], '你好');
          expect(history.any((m) => m['content']!.contains('历史记录（只读背景')), true);
          return hello;
        },
        engine: DeviceEngine(
          transport: (method, args) async {
            if (method == 'status') return {'enabled': true, 'system': true};
            if (args['tool'] == 'device.receipt')
              return {
                'requestId': args['requestId'],
                'outcome': 'verified',
                'value': {'found': true, 'outcome': 'dispatched'},
              };
            writes++;
            return {
              'requestId': args['requestId'],
              'outcome': 'permission_required',
              'summary': '缺权限',
            };
          },
        ),
      );
      await a.send('设置闹钟');
      expect(a.canResume, true);
      await a.abandonPending();
      await a.send('你好');
      expect(writes, 1);
      expect(a.phase, 'done');
      expect(a.pending, isNull);
    },
  );

  test(
    'native receipt from an older version also fences a repeated request',
    () async {
      var writes = 0, lookups = 0;
      final a = AssistantEngine(
        identity: () => 'qa',
        read: () async => null,
        write: (_) async {},
        model: (_, __) async => alarm,
        findPreviousEffect: (tool, args) async {
          lookups++;
          return {'found': true, 'outcome': 'dispatched'};
        },
        engine: DeviceEngine(
          transport: (method, args) async {
            if (method == 'status') return {'enabled': true, 'system': true};
            if (args['tool'] == 'device.receipt')
              return {
                'requestId': args['requestId'],
                'outcome': 'verified',
                'value': {'found': true, 'outcome': 'dispatched'},
              };
            writes++;
            throw StateError('Must not dispatch');
          },
        ),
      );
      await a.send('新的聊天');
      expect(lookups, 1);
      expect(writes, 0);
      expect(a.phase, 'awaiting_verification');
    },
  );

  test(
    'normalized schedule protects reordered weekdays and changed labels',
    () {
      final first = ToolSubmission.fingerprintFor('clock.alarm.create', {
        'hour': 7,
        'minute': 15,
        'days': [6, 2, 2],
        'label': '起床',
      });
      final next = ToolSubmission.fingerprintFor('clock.alarm.create', {
        'hour': 7,
        'minute': 15,
        'days': [2, 6],
        'label': '新的名字',
        'vibrate': true,
      });
      expect(first, next);
      expect(
        first,
        isNot(
          ToolSubmission.fingerprintFor('clock.alarm.create', {
            'hour': 8,
            'minute': 15,
            'days': [2, 6],
          }),
        ),
      );
    },
  );

  test('chat edits and a new topic preserve the durable alarm fence', () async {
    final disk = MemoryChats();
    var calls = 0;
    final store = DemoStore(settings: TestModels(), storage: disk);
    await store.restore();
    final coordinator = bind(
      store,
      (_, __) async => alarm,
      invoke: (args) async {
        if (args['tool'] == 'device.receipt')
          return {
            'requestId': args['requestId'],
            'outcome': 'verified',
            'value': {'found': true, 'outcome': 'dispatched'},
          };
        calls++;
        return {
          'requestId': args['requestId'],
          'outcome': 'dispatched',
          'summary': '已提交',
        };
      },
    );
    store.newChat(personaId: cloudPersonaId);
    final chat = store.conversations[store.conversation];
    store.send('设置闹钟');
    await waitForReply(store);
    expect(chat.toolSubmissions, hasLength(1));
    await coordinator.confirmResult(chat);
    expect(
      chat.messages.where((m) => m.toolExecution?.outcome == 'user_confirmed'),
      hasLength(1),
    );
    expect(chat.messages.last.text, contains('按你的确认'));
    expect(calls, 1);
    expect(store.deleteRound(chat.id, chat.messages.first), true);
    expect(chat.assistantJournal, isNull);
    expect(chat.toolSubmissions.single.protected, true);
    store.send('我们换个话题');
    await waitForReply(store);
    expect(calls, 1);
    expect(coordinator.engineFor(chat).phase, 'done');
    expect(store.send('不设置了，聊别的'), true);
    await waitForReply(store);
    expect(calls, 1);
    await store.saveChats();
    final restored = DemoStore(settings: TestModels(), storage: disk);
    await restored.restore();
    expect(
      restored.conversations
          .firstWhere((c) => c.id == chat.id)
          .toolSubmissions
          .single
          .protected,
      true,
    );
    store.dispose();
    restored.dispose();
  });

  testWidgets(
    'pending clock dispatch is not shown as failure and confirmation does no tool work',
    (tester) async {
      var confirms = 0, repeats = 0;
      final message = toolRecord('clock', outcome: 'dispatched');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CloudExecutionDisclosure(
              messages: [message],
              phase: 'awaiting_verification',
              expanded: false,
              onToggle: () {},
              onConfirmResult: () => confirms++,
            ),
          ),
        ),
      );
      expect(find.text('执行过程 · 已提交 · 待核对 · 1 个步骤'), findsOneWidget);
      expect(find.textContaining('未完成'), findsNothing);
      await tester.tap(find.text('已确认任务完成'));
      expect(confirms, 1);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CloudExecutionDisclosure(
              messages: [message],
              phase: 'confirmation',
              expanded: false,
              onToggle: () {},
              onResume: () => repeats++,
            ),
          ),
        ),
      );
      expect(find.text('确认再次执行此操作'), findsOneWidget);
      expect(repeats, 0);
      await tester.tap(find.text('确认再次执行此操作'));
      expect(repeats, 1);
    },
  );
}

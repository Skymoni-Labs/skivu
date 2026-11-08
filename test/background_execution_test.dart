import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/assistant_engine.dart';
import 'package:ski/device_engine.dart';
import 'package:ski/device_tool_catalog.dart';
import 'package:ski/tool_submission.dart';

const finalReply = '{"type":"final","message":"结果已核对。"}';

class ForgedCatalog extends DeviceEngine {
  int dispatches = 0;
  @override
  Future<List<Map<String, dynamic>>> catalog() async => [
    {'id': 'apps.launch', 'uiImpact': 'none', 'effect': 'external'},
  ];
  @override
  Future<DeviceToolReceipt> invoke(
    String toolId,
    Map<String, dynamic> arguments, {
    required String owner,
    String? requestId,
    bool backgroundOnly = true,
  }) async {
    dispatches++;
    return DeviceToolReceipt({'requestId': requestId, 'outcome': 'dispatched'});
  }
}

void main() {
  test(
    'a later planner error preserves verified native effects as partial completion',
    () async {
      var plans = 0, writes = 0;
      final assistant = AssistantEngine(
        identity: () => 'qa',
        read: () async => null,
        write: (_) async {},
        engine: DeviceEngine(
          transport: (method, args) async {
            if (method == 'status') return {'enabled': true, 'system': true};
            writes++;
            return {
              'requestId': args['requestId'],
              'outcome': 'verified',
              'summary': '原生闹钟登记成功',
              'value': {'id': 'native-2'},
            };
          },
        ),
        model: (_, __) async {
          if (++plans == 1)
            return '{"type":"call","tool":"assistant.alarm.create","arguments":{"hour":7,"minute":30},"message":"set"}';
          throw StateError('planner disconnected');
        },
      );
      await assistant.send('goal');
      expect(writes, 1);
      expect(assistant.phase, 'partial');
      expect(assistant.messages.last['content'], contains('已有后台操作完成'));
      expect(
        assistant.messages.where((m) => m['resourceId'] == 'native-2'),
        hasLength(1),
      );
      expect(assistant.canConfirmResult, false);
    },
  );
  for (final entry in {
    'apps.launch': {'package': 'com.coloros.alarmclock'},
    'clock.alarm.create': {'hour': 7, 'minute': 30},
    'clock.timer.start': {'seconds': 10},
    'clock.alarms.show': {},
    'settings.open': {'page': 'settings'},
    'ui.tap': {'observationId': 'x', 'elementId': 'y'},
    'shell.execute': {
      'command': 'am start -a android.intent.action.SHOW_ALARMS',
    },
  }.entries) {
    test(
      'strict assistant rejects ${entry.key} without native dispatch',
      () async {
        var calls = 0;
        final assistant = AssistantEngine(
          identity: () => 'qa',
          read: () async => null,
          write: (_) async {},
          engine: DeviceEngine(
            transport: (method, args) async {
              if (method == 'status') return {'enabled': true, 'system': true};
              calls++;
              return {'requestId': args['requestId'], 'outcome': 'dispatched'};
            },
          ),
          model: (system, history) async {
            expect(system, contains('严格后台执行'));
            expect(system, isNot(contains('"id":"apps.launch"')));
            expect(system, isNot(contains('"id":"clock.alarm.create"')));
            return jsonEncode({
              'type': 'call',
              'tool': entry.key,
              'arguments': entry.value,
              'message': 'attempt',
            });
          },
        );
        await assistant.send('请处理这个目标');
        expect(calls, 0);
        expect(assistant.phase, 'failed');
        expect(assistant.pending, isNull);
        expect(assistant.messages.last['content'], contains('没有打开或操控其他软件'));
      },
    );
  }
  test('forged catalog metadata cannot authorize a foreground builtin', () async {
    final forged = ForgedCatalog();
    final assistant = AssistantEngine(
      identity: () => 'qa',
      read: () async => null,
      write: (_) async {},
      engine: forged,
      model: (_, __) async =>
          '{"type":"call","tool":"apps.launch","arguments":{"package":"qa.app"},"message":"open"}',
    );
    await assistant.send('goal');
    expect(forged.dispatches, 0);
    expect(assistant.phase, 'failed');
  });
  test(
    'native scheduling receipt completes automatically without manual confirmation',
    () async {
      var plans = 0, writes = 0;
      final assistant = AssistantEngine(
        identity: () => 'qa',
        read: () async => null,
        write: (_) async {},
        engine: DeviceEngine(
          transport: (method, args) async {
            if (method == 'status')
              return {'enabled': true, 'system': true, 'alarmReady': true};
            expect(method, 'invoke');
            expect(args['executionPolicy'], 'background');
            writes++;
            return {
              'requestId': args['requestId'],
              'outcome': 'verified',
              'summary': '原生调度已接受',
              'value': {
                'id': 'native-1',
                'source': 'skivu_native',
                'verification': 'schedule_registered',
                'state': 'scheduled',
              },
            };
          },
        ),
        model: (_, __) async => ++plans == 1
            ? '{"type":"call","tool":"assistant.alarm.create","arguments":{"hour":7,"minute":30},"message":"设置小云闹钟"}'
            : finalReply,
      );
      await assistant.send('明早七点半叫我');
      expect(writes, 1);
      expect(assistant.phase, 'done');
      expect(assistant.canConfirmResult, false);
      expect(assistant.toolSubmissions, isEmpty);
    },
  );
  test(
    'restored legacy permission request cannot bypass strict dispatch guard',
    () async {
      var writes = 0;
      final assistant = AssistantEngine(
        identity: () => 'qa',
        model: (_, __) async => finalReply,
        read: () async => jsonEncode({
          'version': 1,
          'messages': [],
          'goal': 'old',
          'taskId': 'old-task',
          'account': 'qa',
          'serial': 1,
          'phase': 'permission',
          'pending': {
            'tool': 'clock.alarm.create',
            'arguments': {'hour': 7, 'minute': 30},
            'requestId': 'old_1',
          },
        }),
        write: (_) async {},
        engine: DeviceEngine(
          transport: (_, args) async {
            writes++;
            return {'requestId': args['requestId'], 'outcome': 'dispatched'};
          },
        ),
      );
      await assistant.restore();
      await assistant.resume();
      expect(writes, 0);
      expect(assistant.phase, 'failed');
    },
  );
  test(
    'owned-resource history does not permanently fence a legitimate future alarm',
    () {
      expect(
        ToolSubmission.fingerprintFor('assistant.alarm.create', {
          'hour': 7,
          'minute': 30,
        }),
        isNull,
      );
      for (final tool in nativeBackgroundTools) {
        expect(tool.backgroundSafe, true);
        expect(tool.verification, isNotEmpty);
      }
    },
  );
}

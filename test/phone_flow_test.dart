import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/assistant_engine.dart';
import 'package:ski/device_engine.dart';
import 'package:ski/device_tool_catalog.dart';
import 'package:ski/tool_result_details.dart';
import 'package:ski/phone_task_adapters.dart';

Map<String, dynamic> flowPlan() => {
  'package': 'example.exercise',
  'steps': [
    for (final text in ['Option A', 'Option B'])
      {
        'id': text.endsWith('A') ? 'a' : 'b',
        'action': 'tap',
        'selector': {'text': text},
        'guard': {
          'kind': 'exists',
          'selector': {'text': 'Question 1'},
        },
        'expect': {
          'kind': 'checked',
          'selector': {'text': text},
          'checked': true,
        },
        'timeoutMs': 3000,
      },
  ],
};

void main() {
  test(
    'choice adapter builds a guarded local flow and deselects wrong multiple answers',
    () {
      final observation = {
        'package': 'example.exercise',
        'observationId': 'old_snapshot',
        'elements': [
          {'id': 'q', 'text': 'Choose positive values'},
          for (final entry in {'a': 'A. -2', 'b': 'B. 2', 'c': 'C. 3'}.entries)
            {
              'id': entry.key,
              'text': entry.value,
              'class': 'android.widget.CheckBox',
              'checkable': true,
              'checked': entry.key == 'a',
            },
        ],
      };
      final q = ChoiceQuestion.extract(observation, ['q'], ['a', 'b', 'c']);
      final plan = q.flow(q.match(['2', '3']), 'example.exercise');
      deviceTool('ui.flow').validate(plan);
      final steps = plan['steps'] as List;
      expect(steps, hasLength(4));
      final all = (steps.first as Map)['expect'] as Map;
      expect(all['kind'], 'all');
      expect((all['conditions'] as List).last, {
        'kind': 'checked',
        'selector': {'text': 'A. -2', 'className': 'android.widget.CheckBox'},
        'checked': false,
      });
      expect(plan.toString(), isNot(contains('old_snapshot')));
      expect(plan.toString(), contains('Choose positive values'));
    },
  );

  test(
    'flow catalog exposes control and read permissions separately',
    () async {
      deviceTool('ui.flow').validate(flowPlan());
      expect(deviceTool('ui.flow').permission, 'device.control');
      expect(deviceTool('ui.flow.read').permission, 'device.observe');
      final engine = DeviceEngine(
        transport: (_, __) async => {
          'enabled': false,
          'control': false,
          'accessibility': false,
        },
      );
      final catalog = await engine.catalog();
      expect(
        catalog.firstWhere((t) => t['id'] == 'ui.flow')['available'],
        false,
      );
      expect(
        catalog.firstWhere((t) => t['id'] == 'ui.flow.read')['available'],
        true,
      );
    },
  );

  test(
    'flow arguments reject old IDs, injected ownership and negative waits',
    () {
      for (final args in [
        {...flowPlan(), 'owner': 'other'},
        {
          ...flowPlan(),
          'steps': [
            {
              ...((flowPlan()['steps'] as List).first as Map),
              'elementId': 'old',
            },
          ],
        },
        {
          ...flowPlan(),
          'steps': [
            {...((flowPlan()['steps'] as List).first as Map), 'timeoutMs': -1},
          ],
        },
      ]) {
        expect(
          () => deviceTool('ui.flow').validate(args),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'one model plan executes multiple phone steps and receives one receipt',
    () async {
      var models = 0, invokes = 0;
      final engine = AssistantEngine(
        identity: () => 'same-model',
        read: () async => null,
        write: (_) async {},
        engine: DeviceEngine(
          transport: (method, args) async {
            if (method == 'status')
              return {'enabled': true, 'control': true, 'accessibility': true};
            invokes++;
            expect(args['tool'], 'ui.flow');
            expect((args['arguments'] as Map)['steps'], hasLength(2));
            return {
              'requestId': args['requestId'],
              'tool': 'ui.flow',
              'outcome': 'verified',
              'summary': 'two actual fixture steps verified',
              'value': {
                'completedSteps': 2,
                'totalSteps': 2,
                'elapsedMs': 240,
                'hasUnverifiedActions': false,
              },
            };
          },
        ),
        model: (system, _) async {
          expect(system, contains('手机连续操作优先使用 ui.flow'));
          return jsonEncode(
            models++ == 0
                ? {
                    'type': 'call',
                    'tool': 'ui.flow',
                    'arguments': flowPlan(),
                    'message': '选择两个选项并核验',
                  }
                : {'type': 'final', 'message': '已完成两项选择'},
          );
        },
      );
      await engine.send('选择两个指定选项');
      expect(
        models,
        2,
      ); // One planning request and one final response, not one per step.
      expect(invokes, 1);
      expect(engine.modelTimings, hasLength(2));
      expect(engine.workspaceSnapshot['modelRequests'], 2);
      expect(engine.phase, 'done');
      expect(engine.hasUnverifiedEffects, false);
      final record = engine.messages.singleWhere(
        (m) => m['outcome'] == 'verified',
      );
      expect(record['resultDetail'], contains('2/2 步'));
      engine.dispose();
    },
  );

  test(
    'cancelled flow with an uncertain child keeps the effect fence',
    () async {
      var model = 0;
      final engine = AssistantEngine(
        identity: () => 'same-model',
        read: () async => null,
        write: (_) async {},
        engine: DeviceEngine(
          transport: (method, args) async => method == 'status'
              ? {'enabled': true, 'control': true, 'accessibility': true}
              : {
                  'requestId': args['requestId'],
                  'outcome': 'cancelled',
                  'value': {
                    'hasUnverifiedActions': true,
                    'completedSteps': 0,
                    'totalSteps': 2,
                  },
                },
        ),
        model: (_, __) async => jsonEncode(
          model++ == 0
              ? {
                  'type': 'call',
                  'tool': 'ui.flow',
                  'arguments': flowPlan(),
                  'message': '选择',
                }
              : {'type': 'final', 'message': '已停止'},
        ),
      );
      await engine.send('测试停止');
      expect(engine.hasUnverifiedEffects, true);
      expect(engine.phase, 'awaiting_verification');
      engine.dispose();
    },
  );

  test(
    'resuming a verified native flow reconciles the original parent effect',
    () async {
      var model = 0;
      String? original;
      final engine = AssistantEngine(
        identity: () => 'same-model',
        read: () async => null,
        write: (_) async {},
        engine: DeviceEngine(
          transport: (method, args) async {
            if (method == 'status')
              return {'enabled': true, 'control': true, 'accessibility': true};
            if (args['tool'] == 'ui.flow') {
              original = args['requestId'] as String;
              return {
                'requestId': original,
                'outcome': 'unknown',
                'value': {'hasUnverifiedActions': true},
              };
            }
            expect((args['arguments'] as Map)['originalRequestId'], original);
            return {
              'requestId': args['requestId'],
              'outcome': 'verified',
              'value': {
                'verifiedRequestId': original,
                'hasUnverifiedActions': false,
              },
            };
          },
        ),
        model: (_, __) async {
          final turn = model++;
          return jsonEncode(
            turn == 0
                ? {
                    'type': 'call',
                    'tool': 'ui.flow',
                    'arguments': flowPlan(),
                    'message': '执行',
                  }
                : turn == 1
                ? {
                    'type': 'call',
                    'tool': 'ui.flow.resume',
                    'arguments': {'originalRequestId': original},
                    'message': '只核对原步骤并继续',
                  }
                : {'type': 'final', 'message': '原流程已核验'},
          );
        },
      );
      await engine.send('继续核对原流程');
      expect(engine.hasUnverifiedEffects, false);
      expect(engine.phase, 'done');
      engine.dispose();
    },
  );

  test(
    'pausing a local phone flow sends cancellation before waiting for it',
    () async {
      final started = Completer<void>(),
          answer = Completer<Map<String, dynamic>>();
      var models = 0, cancels = 0;
      String? activeId;
      final engine = AssistantEngine(
        identity: () => 'same-model',
        read: () async => null,
        write: (_) async {},
        engine: DeviceEngine(
          transport: (method, args) async {
            if (method == 'status')
              return {'enabled': true, 'control': true, 'accessibility': true};
            if (method == 'cancelRequest') {
              cancels++;
              expect(args['requestId'], activeId);
              answer.complete({
                'requestId': activeId,
                'outcome': 'cancelled',
                'value': {'hasUnverifiedActions': true},
              });
              return {'outcome': 'cancelled'};
            }
            activeId = args['requestId'] as String;
            started.complete();
            return answer.future;
          },
        ),
        model: (_, __) async {
          models++;
          return jsonEncode({
            'type': 'call',
            'tool': 'ui.flow',
            'arguments': flowPlan(),
            'message': '执行',
          });
        },
      );
      final running = engine.send('暂停测试');
      await started.future;
      engine.requestPause();
      for (var i = 0; i < 30 && engine.phase != 'paused'; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(cancels, 1);
      expect(models, 1);
      expect(engine.phase, 'paused');
      await engine.stop();
      await running;
      engine.dispose();
    },
  );

  test('flow summaries present progress without raw plans or selectors', () {
    final details = toolResultDetails('ui.flow', flowPlan(), {
      'value': {
        'completedSteps': 1,
        'totalSteps': 2,
        'elapsedMs': 300,
        'currentStep': 1,
      },
    });
    expect(details['resultDetail'], '1/2 步 · 300 毫秒 · 停在第 2 步');
    expect(details.toString(), isNot(contains('Option A')));
  });
}

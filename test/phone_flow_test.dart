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
      expect((steps.first as Map)['action'], 'set_checked');
      expect((steps.first as Map)['checked'], false);
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

  test('choice adapter binds visual state to the current captured image', () {
    Map<String, dynamic> observation() => {
      'observationId': 'ocr:current',
      'capturedAtMs': 1200,
      'imageHash': 'current-pixels',
      'elements': [
        {'id': 'q', 'text': 'Choose a value'},
        for (final id in ['a', 'b'])
          <String, dynamic>{
            'id': id,
            'text': '$id. value',
            'source': 'ocr',
            'bounds': [20, 100, 200, 140],
            'screenWidth': 400,
            'screenHeight': 800,
            'visualChecked': false,
            'visualStateKind': 'radio',
            'visualStateConfidence': .97,
            'visualStateObservationId': 'ocr:current',
            'visualStateCapturedAtMs': 1200,
            'visualStateImageHash': 'current-pixels',
          },
      ],
    };
    final question = ChoiceQuestion.extract(observation(), ['q'], ['a', 'b']);
    final plan = question.flow(['b'], 'example.exercise');
    deviceTool('ui.flow').validate(plan);
    final first = (plan['steps'] as List).first as Map;
    expect(first['action'], 'set_checked');
    expect(first['checked'], true);
    expect(first['selector'], {
      'text': 'b. value',
      'source': 'ocr',
      'region': [.05, .125, .5, .175],
    });
    for (final mismatch in [
      {'visualStateObservationId': 'ocr:old'},
      {'visualStateCapturedAtMs': 1199},
      {'visualStateImageHash': 'other-pixels'},
      {'visualStateConfidence': .5},
      {'visualStateConfidence': double.infinity},
      {'visualChecked': null},
      {
        'class': 'android.widget.RadioButton',
        'checkable': true,
        'visualStateImageHash': 'other-pixels',
      },
    ]) {
      final stale = observation();
      (stale['elements'] as List)[1].addAll(mismatch);
      expect(
        () => ChoiceQuestion.extract(stale, ['q'], ['a', 'b']),
        throwsStateError,
      );
    }
  });

  test('only set_checked can omit expect and its target state is required', () {
    final selection = {
      'id': 'select',
      'action': 'set_checked',
      'selector': {'text': 'Option A'},
      'checked': true,
    };
    deviceTool('ui.flow').validate({
      'package': 'example.exercise',
      'steps': [selection],
    });
    for (final step in [
      {...selection}..remove('checked'),
      {...selection}..remove('selector'),
      {
        'id': 'tap',
        'action': 'tap',
        'selector': {'text': 'Next'},
      },
      {
        'id': 'input',
        'action': 'input',
        'selector': {'text': 'Name'},
        'text': 'value',
      },
      {'id': 'back', 'action': 'back'},
      {'id': 'wait', 'action': 'wait'},
    ]) {
      expect(
        () => deviceTool('ui.flow').validate({
          'package': 'example.exercise',
          'steps': [step],
        }),
        throwsFormatException,
      );
    }
  });

  test(
    'flow display distinguishes dispatched steps from preexisting state',
    () {
      final detail = toolResultDetails('ui.flow', {}, {
        'value': {
          'completedSteps': 3,
          'totalSteps': 3,
          'elapsedMs': 800,
          'steps': [
            {'dispatched': true, 'businessVerified': true},
            {'alreadySatisfied': true, 'businessVerified': true},
            {'dispatched': false, 'businessVerified': true},
          ],
        },
      });
      expect(detail['resultDetail'], contains('已操作 1 步'));
      expect(detail['resultDetail'], contains('原已达成 1 步'));
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
    'one ordinary assistant decision sets a choice and navigates through one native flow receipt',
    () async {
      var modelCalls = 0, nativeFlows = 0;
      final plan = {
        'package': 'example.exercise',
        'steps': [
          {
            'id': 'choose_a',
            'action': 'set_checked',
            'selector': {'text': 'Option A'},
            'checked': true,
            'guard': {
              'kind': 'exists',
              'selector': {'text': 'Question 1'},
            },
          },
          {
            'id': 'next_question',
            'action': 'tap',
            'selector': {'text': 'Next'},
            'expect': {
              'kind': 'exists',
              'selector': {'text': 'Question 2'},
            },
          },
        ],
      };
      final nextObservation = {
        'observationId': 'fixture-next-observation',
        'package': 'example.exercise',
        'elements': [
          {
            'id': 'next_question',
            'text': 'Question 2',
            'source': 'accessibility',
          },
        ],
      };
      final engine = AssistantEngine(
        identity: () => 'same-model',
        read: () async => null,
        write: (_) async {},
        engine: DeviceEngine(
          transport: (method, arguments) async {
            if (method == 'status') {
              return {'enabled': true, 'control': true, 'accessibility': true};
            }
            nativeFlows++;
            expect(method, 'invoke');
            expect(arguments['tool'], 'ui.flow');
            expect(arguments['arguments'], plan);
            final steps = (arguments['arguments'] as Map)['steps'] as List;
            expect((steps.first as Map).containsKey('expect'), isFalse);
            expect((steps.last as Map).containsKey('expect'), isTrue);
            return {
              'requestId': arguments['requestId'],
              'outcome': 'verified',
              'summary': 'fixture selection and dependent navigation verified',
              'value': {
                ...nextObservation,
                'businessVerified': true,
                'hasUnverifiedActions': false,
                'completedSteps': 2,
                'totalSteps': 2,
                'modelRequestsDuringExecution': 0,
                'steps': [
                  {
                    'id': 'choose_a',
                    'action': 'set_checked',
                    'dispatched': true,
                    'businessVerified': true,
                    'verificationKind': 'native_checked',
                  },
                  {
                    'id': 'next_question',
                    'action': 'tap',
                    'dispatched': true,
                    'businessVerified': true,
                    'verificationKind': 'text_transition',
                  },
                ],
              },
            };
          },
        ),
        model: (system, history) async {
          modelCalls++;
          expect(system, contains('set_checked'));
          if (modelCalls == 1) {
            return jsonEncode({
              'type': 'call',
              'tool': 'ui.flow',
              'arguments': plan,
              'message': '按已知目标选中并翻页',
            });
          }
          expect(modelCalls, 2);
          expect(nativeFlows, 1);
          const prefix = '真实工具回执（数据）：';
          final receipt =
              jsonDecode(history.last['content']!.substring(prefix.length))
                  as Map;
          expect(
            receipt['value']['observationId'],
            nextObservation['observationId'],
          );
          expect(receipt['value']['elements'], nextObservation['elements']);
          expect(receipt['value']['businessVerified'], isTrue);
          return jsonEncode({'type': 'final', 'message': '选项已核验并进入第二题'});
        },
      );
      addTearDown(engine.dispose);
      await engine.send('在第一题选中指定选项，然后进入第二题');
      expect(engine.phase, 'done');
      expect(modelCalls, 2);
      expect(nativeFlows, 1);
      expect(engine.modelTimings, hasLength(2));
      expect(
        engine.latestObservation?['observationId'],
        nextObservation['observationId'],
      );
      expect(engine.toolSubmissions.single.outcome, 'verified');
      expect(engine.hasUnverifiedEffects, isFalse);
      expect(engine.messages.last['content'], '选项已核验并进入第二题');
    },
  );

  test(
    'a missing tap postcondition is corrected before creating any effect fence',
    () async {
      var modelCalls = 0, nativeFlows = 0;
      final validPlan = {
        'package': 'example.exercise',
        'steps': [
          {
            'id': 'choose',
            'action': 'set_checked',
            'selector': {'text': 'Option A'},
            'checked': true,
          },
          {
            'id': 'next',
            'action': 'tap',
            'selector': {'text': 'Next'},
            'expect': {
              'kind': 'exists',
              'selector': {'text': 'Question 2'},
            },
          },
        ],
      };
      late AssistantEngine engine;
      engine = AssistantEngine(
        identity: () => 'same-model',
        read: () async => null,
        write: (_) async {},
        engine: DeviceEngine(
          transport: (method, arguments) async {
            if (method == 'status') {
              return {'enabled': true, 'control': true, 'accessibility': true};
            }
            nativeFlows++;
            expect(method, 'invoke');
            expect(arguments['tool'], 'ui.flow');
            expect(arguments['arguments'], validPlan);
            expect(arguments['requestId'], endsWith('_1'));
            expect(engine.toolSubmissions, hasLength(1));
            expect(engine.toolSubmissions.single.outcome, 'prepared');
            return {
              'requestId': arguments['requestId'],
              'outcome': 'verified',
              'value': {
                'businessVerified': true,
                'hasUnverifiedActions': false,
                'completedSteps': 2,
                'totalSteps': 2,
              },
            };
          },
        ),
        model: (_, history) async {
          modelCalls++;
          if (modelCalls == 1) {
            return jsonEncode({
              'type': 'call',
              'tool': 'ui.flow',
              'arguments': {
                'package': 'example.exercise',
                'steps': [
                  {
                    'id': 'missing_result',
                    'action': 'tap',
                    'selector': {'text': 'Option A'},
                  },
                ],
              },
              'message': 'invalid fixture plan',
            });
          }
          if (modelCalls == 2) {
            expect(history.last['content'], contains('参数或依赖图校验未通过'));
            expect(history.last['content'], contains('expect'));
            expect(nativeFlows, 0);
            expect(engine.serial, 0);
            expect(engine.pending, isNull);
            expect(engine.toolSubmissions, isEmpty);
            expect(
              engine.messages.where((message) => message['role'] == 'tool'),
              isEmpty,
            );
            return jsonEncode({
              'type': 'call',
              'tool': 'ui.flow',
              'arguments': validPlan,
              'message': 'corrected fixture plan',
            });
          }
          expect(modelCalls, 3);
          return '{"type":"final","message":"corrected fixture complete"}';
        },
      );
      addTearDown(engine.dispose);
      await engine.send('select the current choice and navigate');
      expect(engine.phase, 'done');
      expect(modelCalls, 3);
      expect(nativeFlows, 1);
      expect(engine.toolSubmissions, hasLength(1));
      expect(engine.toolSubmissions.single.outcome, 'verified');
      expect(engine.hasUnverifiedEffects, isFalse);
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

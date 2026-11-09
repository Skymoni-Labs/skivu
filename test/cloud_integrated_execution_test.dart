import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/cloud_execution_state.dart';
import 'package:ski/assistant_engine.dart';
import 'package:ski/cloud_coding_tools.dart';
import 'package:ski/device_engine.dart';
import 'package:ski/phone_task_adapters.dart';
import 'package:ski/tool_execution.dart';
import 'package:ski/tool_result_details.dart';
import 'package:ski/task_result_card.dart';
import 'package:ski/state.dart';

class CodingFake implements AssistantExtensions {
  CodingFake(this.answer);
  final Future<Map<String, dynamic>> Function(
    String,
    Map<String, dynamic>,
    String,
  )
  answer;
  @override
  Future<List<Map<String, dynamic>>> catalog() async =>
      CloudCodingTools.definitions;
  @override
  Future<Map<String, dynamic>> cancel() async => {'outcome': 'cancelled'};
  @override
  Future<DeviceToolReceipt> invoke(
    String tool,
    Map<String, dynamic> args,
    String requestId,
    void Function() check,
  ) async => DeviceToolReceipt({
    'requestId': requestId,
    'tool': tool,
    ...await answer(tool, args, requestId),
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'file delivery does not create a duplicate generic task result card',
    () {
      final event = ToolExecutionEvent(
        taskId: 't',
        requestId: 'r',
        tool: 'coding.deliver.prepare',
        purpose: '只交付最终文件',
        effect: 'write',
        outcome: 'verified',
        artifactIds: 'artifact_${'a' * 32}',
      );
      final tool = Message(false, '已交付')
        ..toolReceipt = true
        ..toolExecution = event;
      expect(
        TaskResult.fromMessages([
          tool,
          Message(false, '文件已准备好'),
        ], phase: 'done'),
        isNull,
      );
    },
  );
  AssistantEngine engine(AssistantModel model, AssistantExtensions tools) =>
      AssistantEngine(
        identity: () => 'model',
        model: model,
        extensions: tools,
        engine: DeviceEngine(
          transport: (method, args) async => {
            'enabled': true,
            'outcome': 'cancelled',
          },
        ),
        read: () async => null,
        write: (_) async {},
      );
  test(
    'confirmed output truncation retries a short action without dispatching partial code',
    () async {
      var rounds = 0, calls = 0;
      final a = engine(
        (_, history) async {
          if (++rounds == 1) throw const AssistantOutputLimit(2048);
          if (rounds == 2) {
            expect(history.last['content'], contains('没有派发'));
            return jsonEncode({
              'type': 'call',
              'tool': 'coding.workbook.create',
              'arguments': {'projectId': 'project_a', 'path': 'blank.xlsx'},
              'message': '创建空白表格',
            });
          }
          return '{"type":"final","message":"空白表格已生成"}';
        },
        CodingFake((_, __, ___) async {
          calls++;
          return {
            'outcome': 'verified',
            'value': {'path': 'blank.xlsx', 'sha256': 'a'},
          };
        }),
      );
      await a.send('生成空白 Excel');
      expect(calls, 1);
      expect(a.phase, 'done');
      expect(a.modelResponseIssues.single['kind'], 'output_limit');
    },
  );
  test(
    'repeated API output limits give a specific reason and never dispatch an action',
    () async {
      var calls = 0, rounds = 0;
      final a = engine(
        (_, __) async {
          rounds++;
          throw const AssistantOutputLimit(512);
        },
        CodingFake((_, __, ___) async {
          calls++;
          return {'outcome': 'verified'};
        }),
      );
      await a.send('生成文件');
      expect(rounds, 3);
      expect(calls, 0);
      expect(a.phase, 'failed');
      expect(a.messages.last['content'], contains('512 tokens'));
      expect(a.messages.last['content'], contains('未派发'));
    },
  );
  test(
    'unmatched UI readback can be refined without repeating the action',
    () async {
      var round = 0;
      var taps = 0;
      String? actionId;
      final a = AssistantEngine(
        identity: () => 'model',
        model: (_, __) async => switch (++round) {
          1 => jsonEncode({
            'type': 'call',
            'tool': 'ui.tap',
            'arguments': {'observationId': 'page', 'elementId': 'tab'},
            'message': '切换标签',
          }),
          2 || 3 => jsonEncode({
            'type': 'call',
            'tool': 'ui.verify',
            'arguments': {
              'requestId': actionId,
              'expect': {'kind': 'selected', 'selected': true},
            },
            'message': '读取实际状态',
          }),
          _ => '{"type":"final","message":"已核对"}',
        },
        engine: DeviceEngine(
          transport: (method, args) async {
            if (method != 'invoke')
              return {'enabled': true, 'control': true, 'accessibility': true};
            final id = args['requestId'];
            if (args['tool'] == 'ui.tap') {
              taps++;
              actionId = id as String;
              return {'requestId': id, 'outcome': 'dispatched'};
            }
            return {
              'requestId': id,
              'outcome': round == 2 ? 'unknown' : 'verified',
              'value': {
                'matched': round == 3,
                'verifiedRequestId': round == 3 ? actionId : null,
                'observationId': 'new',
                'elements': [],
              },
            };
          },
        ),
        read: () async => null,
        write: (_) async {},
      );
      await a.send('导航并核对');
      expect(taps, 1);
      expect(round, 4);
      expect(a.phase, 'done');
      expect(a.hasUnverifiedEffects, false);
      a.messages.insert(0, {
        'role': 'tool',
        'tool': 'ui.tap',
        'taskId': 'old_unrelated_task',
        'outcome': 'unknown',
      });
      Map<dynamic, dynamic>? published;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(cloudExecutionChannel, (call) async {
            published = call.arguments as Map;
            return null;
          });
      CloudExecutionState(a, 'qa').publish();
      await Future<void>.delayed(Duration.zero);
      expect(published?['phase'], 'completed');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(cloudExecutionChannel, null);
    },
  );
  test(
    'system navigation is verified by its actual resolved package readback',
    () async {
      var round = 0;
      final a = AssistantEngine(
        identity: () => 'model',
        model: (_, __) async => switch (++round) {
          1 => jsonEncode({
            'type': 'call',
            'tool': 'settings.open',
            'arguments': {'page': 'settings'},
            'message': '打开设置',
          }),
          2 => jsonEncode({
            'type': 'call',
            'tool': 'ui.observe',
            'arguments': {},
            'message': '核对设置页面',
          }),
          _ => '{"type":"final","message":"已观察设置"}',
        },
        engine: DeviceEngine(
          transport: (method, args) async {
            if (method != 'invoke')
              return {
                'enabled': true,
                'control': true,
                'system': true,
                'accessibility': true,
              };
            return {
              'requestId': args['requestId'],
              'outcome': args['tool'] == 'settings.open'
                  ? 'dispatched'
                  : 'verified',
              'value': args['tool'] == 'settings.open'
                  ? {'expectedPackage': 'com.android.settings'}
                  : {
                      'package': 'com.android.settings',
                      'observationId': 'page',
                      'elements': [],
                    },
            };
          },
        ),
        read: () async => null,
        write: (_) async {},
      );
      await a.send('打开设置并观察');
      expect(a.phase, 'done');
      expect(
        a.messages
            .where((m) => m['tool'] == 'settings.open' && m['outcome'] != null)
            .single['outcome'],
        'verified',
      );
    },
  );
  test('running command cannot become a completed task on final prose', () async {
    var round = 0;
    final a = engine(
      (_, __) async => ++round == 1
          ? '${jsonEncode({
              'type': 'call',
              'tool': 'coding.exec.start',
              'arguments': {'projectId': 'project_a', 'command': 'node app.mjs'},
              'message': '运行',
            })}'
          : '{"type":"final","message":"完成"}',
      CodingFake(
        (_, __, ___) async => {
          'outcome': 'verified',
          'value': {
            'id': 'job_a',
            'state': 'running',
            'businessVerified': false,
          },
        },
      ),
    );
    await a.send('运行程序');
    expect(a.phase, 'awaiting_verification');
    expect(a.hasUnverifiedEffects, true);
    expect(a.activeCodingJobs, {'job_a'});
    await a.stop();
    expect(a.activeCodingJobs, isEmpty);
    expect(a.phase, 'stopped');
  });
  test(
    'actual job exit readback releases exactly its original fence',
    () async {
      var round = 0;
      String? startRequest;
      final a = engine(
        (_, __) async => switch (++round) {
          1 => jsonEncode({
            'type': 'call',
            'tool': 'coding.exec.start',
            'arguments': {'projectId': 'project_a', 'command': 'node app.mjs'},
            'message': '运行',
          }),
          2 => jsonEncode({
            'type': 'call',
            'tool': 'coding.jobs.read',
            'arguments': {'jobId': 'job_a'},
            'message': '读取实际退出',
          }),
          _ => ' {"type":"final","message":"已运行并核对"}',
        },
        CodingFake((tool, args, id) async {
          if (tool == 'coding.exec.start') {
            startRequest = id;
            return {
              'outcome': 'verified',
              'value': {
                'id': 'job_a',
                'state': 'running',
                'businessVerified': false,
              },
            };
          }
          return {
            'outcome': 'verified',
            'value': {
              'id': 'job_a',
              'requestId': startRequest,
              'state': 'exited',
              'exitCode': 0,
            },
          };
        }),
      );
      await a.send('运行并检查');
      expect(a.phase, 'done');
      expect(a.hasUnverifiedEffects, false);
      expect(a.activeCodingJobs, isEmpty);
    },
  );
  test(
    'nonzero exit remains failure if the model prematurely finishes',
    () async {
      var round = 0;
      final a = engine(
        (_, __) async => ++round == 1
            ? jsonEncode({
                'type': 'call',
                'tool': 'coding.exec.start',
                'arguments': {'projectId': 'project_a', 'command': 'false'},
                'message': '检查',
              })
            : '{"type":"final","message":"完成"}',
        CodingFake(
          (_, __, ___) async => {
            'outcome': 'verified',
            'value': {
              'id': 'job_a',
              'state': 'exited',
              'exitCode': 1,
              'businessVerified': true,
            },
          },
        ),
      );
      await a.send('检查');
      expect(a.phase, 'failed');
      expect(a.codingCheckFailed, true);
    },
  );
  test('pause is a real dispatch barrier and Stop releases it', () async {
    var calls = 0;
    final planned = Completer<void>(), answer = Completer<String>();
    final a = engine(
      (_, __) async {
        planned.complete();
        return answer.future;
      },
      CodingFake((_, __, ___) async {
        calls++;
        return {'outcome': 'verified'};
      }),
    );
    final running = a.send('创建项目');
    await planned.future;
    a.requestPause();
    answer.complete(
      jsonEncode({
        'type': 'call',
        'tool': 'coding.projects.create',
        'arguments': {'name': 'a'},
        'message': '创建',
      }),
    );
    for (var i = 0; i < 20 && a.phase != 'paused'; i++)
      await Future<void>.delayed(const Duration(milliseconds: 1));
    expect(a.phase, 'paused');
    expect(calls, 0);
    await a.stop();
    await running;
    expect(calls, 0);
    expect(a.phase, 'stopped');
  });
  test('only explicit verified native final artifacts become card IDs', () {
    expect(
      toolResultDetails('coding.files.write', {}, {
        'outcome': 'verified',
        'value': {'path': 'a.xlsx'},
      }),
      isEmpty,
    );
    final ids = 'artifact_${'a' * 32},artifact_${'b' * 32}';
    final details = toolResultDetails('coding.deliver.prepare', {}, {
      'outcome': 'verified',
      'value': {
        'artifacts': [
          {'id': 'artifact_${'a' * 32}'},
          {'id': 'artifact_${'b' * 32}'},
        ],
      },
    });
    final event = ToolExecutionEvent.parse({
      'taskId': 't',
      'requestId': 'r',
      'tool': 'coding.deliver.prepare',
      'purpose': '交付',
      'outcome': 'verified',
      ...details,
    });
    expect(event?.artifactIds, ids);
    expect(
      ToolExecutionEvent.parse({
        ...event!.toJson(),
        'artifactIds': '../../a',
      })?.artifactIds,
      isNull,
    );
  });
  Map<String, dynamic> observation({
    bool multiple = false,
    String id = 'page1',
    String question = '选择正数',
  }) => {
    'observationId': id,
    'elements': [
      {'id': 'q', 'text': question},
      {
        'id': 'a',
        'text': 'A. −2',
        'class': multiple
            ? 'android.widget.CheckBox'
            : 'android.widget.RadioButton',
        'checked': false,
      },
      {
        'id': 'b',
        'text': 'B. 2',
        'class': multiple
            ? 'android.widget.CheckBox'
            : 'android.widget.RadioButton',
        'checked': false,
      },
      {
        'id': 'c',
        'text': 'C. 3',
        'class': multiple
            ? 'android.widget.CheckBox'
            : 'android.widget.RadioButton',
        'checked': false,
      },
    ],
  };
  test(
    'choice matching preserves mathematical signs and distinguishes multiplicity',
    () {
      final single = ChoiceQuestion.extract(
        observation(),
        ['q'],
        ['a', 'b', 'c'],
      );
      expect(single.match(['B']), ['b']);
      expect(single.match(['−2']), ['a']);
      expect(() => single.match(['BC']), throwsStateError);
      final multiple = ChoiceQuestion.extract(
        observation(multiple: true),
        ['q'],
        ['a', 'b', 'c'],
      );
      expect(multiple.match(['B、C']), ['b', 'c']);
      expect(multiple.match(['2', '3']), ['b', 'c']);
      expect(() => multiple.match(['接近2']), throwsStateError);
      expect(
        single.fingerprint,
        isNot(
          ChoiceQuestion.extract(
            observation(question: '选择负数'),
            ['q'],
            ['a', 'b', 'c'],
          ).fingerprint,
        ),
      );
    },
  );
  test('new native observation invalidates an old choice answer', () async {
    var actual = observation();
    final adapter = PhoneTaskAdapters(() => actual);
    final first = await adapter.invoke(
      'adapter.choice.extract',
      {
        'questionIds': ['q'],
        'optionIds': ['a', 'b', 'c'],
      },
      'extract',
      () {},
    );
    actual = observation(id: 'newpage');
    final matched = await adapter.invoke(
      'adapter.choice.match',
      {
        'fingerprint': (first.data['value'] as Map)['fingerprint'],
        'answers': ['B'],
      },
      'match',
      () {},
    );
    expect(matched.outcome, 'failed');
  });
}

import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/assistant_engine.dart';
import 'package:ski/device_engine.dart';

Map<String, dynamic> schema(
  Map<String, dynamic> properties,
  List<String> required,
) => {
  'type': 'object',
  'properties': properties,
  'required': required,
  'additionalProperties': false,
};

class Work extends AssistantExtensions {
  final calls = <String>[];
  final started = <String>{};
  final both = Completer<void>();
  @override
  Future<List<Map<String, dynamic>>> catalog() async => [
    for (final name in ['a', 'b'])
      {
        'id': 'coding.read.$name',
        'effect': 'read',
        'parameters': schema({}, []),
      },
    {
      'id': 'coding.projects.create',
      'effect': 'write',
      'parameters': schema(
        {
          'name': {'type': 'string'},
        },
        ['name'],
      ),
    },
    {
      'id': 'coding.files.write',
      'effect': 'write',
      'parameters': schema(
        {
          'projectId': {'type': 'string'},
          'path': {'type': 'string'},
          'content': {'type': 'string'},
        },
        ['projectId', 'path', 'content'],
      ),
    },
  ];
  @override
  Future<DeviceToolReceipt> invoke(
    String tool,
    Map<String, dynamic> args,
    String id,
    void Function() check,
  ) async {
    calls.add(tool);
    if (tool.startsWith('coding.read.')) {
      started.add(tool);
      if (started.length == 2) both.complete();
      await both.future.timeout(const Duration(seconds: 2));
    }
    return DeviceToolReceipt({
      'outcome': 'verified',
      'requestId': id,
      'tool': tool,
      'summary': 'actual test transport receipt',
      'value': tool == 'coding.projects.create'
          ? {'id': 'project_test'}
          : tool == 'coding.files.write'
          ? {
              'path': args['path'],
              'sha256': 'a' * 64,
              'projectId': args['projectId'],
            }
          : {'number': tool.endsWith('a') ? 2 : 3},
    });
  }

  @override
  Future<Map<String, dynamic>> cancel() async => {'outcome': 'cancelled'};
}

void main() {
  Future<AssistantEngine> runLedger(
    LedgerWork tools,
    List<Map<String, dynamic>> actions,
  ) async {
    var turn = 0;
    final engine = AssistantEngine(
      engine: DeviceEngine(transport: (_, __) async => {'enabled': true}),
      identity: () => 'model',
      read: () async => null,
      write: (_) async {},
      extensions: tools,
      model: (_, __) async => jsonEncode(
        turn < actions.length
            ? {'type': 'call', ...actions[turn++], 'message': '核对当前目标'}
            : {'type': 'final', 'message': '当前核对结果'},
      ),
    );
    await engine.send('检查两个项目并交付');
    return engine;
  }

  Map<String, dynamic> call(String tool, Map<String, dynamic> args) => {
    'tool': tool,
    'arguments': args,
  };

  test(
    'a passing different project cannot hide a failed check and a new goal resets the ledger',
    () async {
      final work = LedgerWork();
      final engine = await runLedger(work, [
        call('coding.jobs.wait', {'jobId': 'job_bad'}),
        call('coding.jobs.wait', {'jobId': 'job_good'}),
      ]);
      expect(engine.codingChecks, {'project_a': false, 'project_b': true});
      expect(engine.phase, 'failed');
      await engine.send('只回复一句你好');
      expect(engine.phase, 'done');
      expect(engine.codingChecks, isEmpty);
      expect(work.calls, hasLength(2));
      engine.dispose();
    },
  );
  test('repairing the original project clears its failed check', () async {
    final engine = await runLedger(LedgerWork(), [
      call('coding.jobs.wait', {'jobId': 'job_bad'}),
      call('coding.jobs.wait', {'jobId': 'job_fixed'}),
    ]);
    expect(engine.phase, 'done');
    expect(engine.codingChecks, {'project_a': true});
    engine.dispose();
  });
  test(
    'a complete different delivery batch cannot hide an earlier partial delivery',
    () async {
      final engine = await runLedger(LedgerWork(), [
        call('coding.deliver.prepare', {'projectId': 'project_a'}),
        call('coding.deliver.prepare', {'projectId': 'project_b'}),
      ]);
      expect(engine.deliveryBatches, {'batch_a': false, 'batch_b': true});
      expect(engine.finalDeliveryVerified, false);
      expect(engine.phase, 'failed');
      engine.dispose();
    },
  );
  test(
    'readback of the original delivery batch resolves only that batch',
    () async {
      final engine = await runLedger(LedgerWork(), [
        call('coding.deliver.prepare', {'projectId': 'project_a'}),
        call('coding.deliver.prepare', {'projectId': 'project_b'}),
        call('coding.artifacts.status', {'batchId': 'batch_a'}),
      ]);
      expect(engine.deliveryBatches, {'batch_a': true, 'batch_b': true});
      expect(engine.finalDeliveryVerified, true);
      expect(engine.phase, 'done');
      engine.dispose();
    },
  );
  test(
    'an unknown code start stays fenced when a planner repeats it',
    () async {
      final work = LedgerWork();
      final action = call('coding.exec.start', {
        'projectId': 'project_a',
        'command': 'write once',
      });
      final engine = await runLedger(work, [action, action]);
      expect(work.calls.where((v) => v == 'coding.exec.start'), hasLength(1));
      expect(engine.hasUnverifiedEffects, true);
      expect(engine.phase, 'awaiting_verification');
      engine.dispose();
    },
  );
  test(
    'DAG parallel reads and dependent project write use the ordinary durable receipt path',
    () async {
      final work = Work();
      var turn = 0;
      String? saved;
      final a = AssistantEngine(
        engine: DeviceEngine(
          transport: (method, args) async => {'enabled': true},
        ),
        identity: () => 'model',
        read: () async => null,
        write: (v) async => saved = v,
        extensions: work,
        model: (_, history) async => ++turn == 1
            ? jsonEncode({
                'type': 'call',
                'tool': 'workflow.batch',
                'message': 'complete workflow',
                'arguments': {
                  'steps': [
                    {'id': 'a', 'tool': 'coding.read.a', 'arguments': {}},
                    {'id': 'b', 'tool': 'coding.read.b', 'arguments': {}},
                    {
                      'id': 'project',
                      'tool': 'coding.projects.create',
                      'arguments': {'name': 'result'},
                      'dependsOn': ['a', 'b'],
                    },
                    {
                      'id': 'file',
                      'tool': 'coding.files.write',
                      'arguments': {
                        'projectId': {
                          r'$step': 'project',
                          'path': ['value', 'id'],
                        },
                        'path': 'answer.txt',
                        'content': '5',
                      },
                    },
                  ],
                },
              })
            : jsonEncode({'type': 'final', 'message': 'done'}),
      );
      await a.send('compute and save');
      expect(
        a.phase,
        'done',
        reason: jsonEncode({
          'messages': a.messages,
          'workflows': a.workflows,
          'submissions': a.toolSubmissions.map((s) => s.toJson()).toList(),
        }),
      );
      expect(work.calls, [
        'coding.read.a',
        'coding.read.b',
        'coding.projects.create',
        'coding.files.write',
      ]);
      expect(a.codingWorkspace['projectId'], 'project_test');
      expect(a.codingWorkspace['files']['answer.txt'], 'a' * 64);
      final journal = jsonDecode(saved!);
      expect((journal['workflows'] as Map).values.single['state'], 'done');
      expect(
        a.messages.where(
          (m) =>
              m['tool'] == 'coding.files.write' && m['outcome'] == 'verified',
        ),
        hasLength(1),
      );
    },
  );
  test(
    'cycles fail before dispatch and never execute part of an invalid graph',
    () async {
      final work = Work();
      final a = AssistantEngine(
        engine: DeviceEngine(transport: (_, __) async => {'enabled': true}),
        identity: () => 'model',
        read: () async => null,
        write: (_) async {},
        extensions: work,
        model: (_, __) async => jsonEncode({
          'type': 'call',
          'tool': 'workflow.batch',
          'message': 'invalid',
          'arguments': {
            'steps': [
              {
                'id': 'a',
                'tool': 'coding.read.a',
                'arguments': {},
                'dependsOn': ['b'],
              },
              {
                'id': 'b',
                'tool': 'coding.read.b',
                'arguments': {},
                'dependsOn': ['a'],
              },
            ],
          },
        }),
      );
      await a.send('read');
      expect(work.calls, isEmpty);
      expect(a.phase, anyOf('failed', 'awaiting_verification'));
      expect(a.messages.last['content'], contains('循环'));
    },
  );
  test('long valid action and code are parsed without universal text caps', () {
    final code = '完整代码\n' * 20000;
    final parsed = AssistantEngine.parse(
      jsonEncode({
        'type': 'call',
        'tool': 'coding.files.write',
        'arguments': {'path': 'main.txt', 'content': code},
        'message': '详细目的 ' * 4000,
      }),
    );
    expect((parsed['arguments'] as Map)['content'], code);
  });
  test(
    'jobs.wait exit receipt verifies the original start without a second execution',
    () async {
      final tools = WaitWork();
      var turn = 0;
      final engine = AssistantEngine(
        engine: DeviceEngine(transport: (_, __) async => {'enabled': true}),
        identity: () => 'model',
        read: () async => null,
        write: (_) async {},
        extensions: tools,
        model: (_, __) async => jsonEncode(
          ++turn == 1
              ? {
                  'type': 'call',
                  'tool': 'coding.exec.start',
                  'arguments': {
                    'projectId': 'project_test',
                    'command': 'node work.mjs',
                  },
                  'message': 'run',
                }
              : turn == 2
              ? {
                  'type': 'call',
                  'tool': 'coding.jobs.wait',
                  'arguments': {'jobId': 'job_test'},
                  'message': 'wait',
                }
              : {'type': 'final', 'message': 'checked'},
        ),
      );
      await engine.send('run and check');
      expect(engine.phase, 'done');
      expect(engine.activeCodingJobs, isEmpty);
      expect(engine.hasUnverifiedEffects, false);
      expect(tools.starts, 1);
      expect(engine.toolSubmissions.single.outcome, 'verified');
    },
  );
}

class LedgerWork extends AssistantExtensions {
  final calls = <String>[];
  @override
  Future<List<Map<String, dynamic>>> catalog() async => [
    for (final tool in [
      'coding.jobs.wait',
      'coding.deliver.prepare',
      'coding.artifacts.status',
      'coding.exec.start',
    ])
      {
        'id': tool,
        'effect':
            tool == 'coding.exec.start' || tool == 'coding.deliver.prepare'
            ? 'write'
            : 'read',
        'parameters': schema({
          for (final key in switch (tool) {
            'coding.jobs.wait' => ['jobId'],
            'coding.artifacts.status' => ['batchId'],
            'coding.exec.start' => ['projectId', 'command'],
            _ => ['projectId'],
          })
            key: {'type': 'string'},
        }, []),
      },
  ];
  @override
  Future<DeviceToolReceipt> invoke(
    String tool,
    Map<String, dynamic> args,
    String id,
    void Function() check,
  ) async {
    calls.add(tool);
    final value = switch (tool) {
      'coding.jobs.wait' => {
        'id': args['jobId'],
        'state': 'exited',
        'projectId': args['jobId'] == 'job_good' ? 'project_b' : 'project_a',
        'exitCode': args['jobId'] == 'job_bad' ? 1 : 0,
      },
      'coding.deliver.prepare' => {
        'batchId': args['projectId'] == 'project_a' ? 'batch_a' : 'batch_b',
        'count': 1,
        'failedCount': args['projectId'] == 'project_a' ? 1 : 0,
      },
      'coding.artifacts.status' => {
        'batchId': args['batchId'],
        'verified': true,
      },
      _ => {'state': 'unknown'},
    };
    return DeviceToolReceipt({
      'tool': tool,
      'requestId': id,
      'outcome': tool == 'coding.exec.start' ? 'unknown' : 'verified',
      'value': value,
    });
  }

  @override
  Future<Map<String, dynamic>> cancel() async => {'outcome': 'cancelled'};
}

class WaitWork extends AssistantExtensions {
  String? startRequest;
  int starts = 0;
  @override
  Future<List<Map<String, dynamic>>> catalog() async => [
    {
      'id': 'coding.exec.start',
      'effect': 'write',
      'parameters': schema(
        {
          'projectId': {'type': 'string'},
          'command': {'type': 'string'},
        },
        ['projectId', 'command'],
      ),
    },
    {
      'id': 'coding.jobs.wait',
      'effect': 'read',
      'parameters': schema(
        {
          'jobId': {'type': 'string'},
        },
        ['jobId'],
      ),
    },
  ];
  @override
  Future<DeviceToolReceipt> invoke(
    String tool,
    Map<String, dynamic> args,
    String id,
    void Function() check,
  ) async {
    if (tool == 'coding.exec.start') {
      starts++;
      startRequest = id;
    }
    return DeviceToolReceipt({
      'tool': tool,
      'requestId': id,
      'outcome': 'verified',
      'summary': 'real transport shape',
      'value': {
        'id': 'job_test',
        'requestId': startRequest,
        'state': tool == 'coding.exec.start' ? 'running' : 'exited',
        'exitCode': tool == 'coding.exec.start' ? null : 0,
        'businessVerified': tool != 'coding.exec.start',
      },
    });
  }

  @override
  Future<Map<String, dynamic>> cancel() async => {'outcome': 'cancelled'};
}

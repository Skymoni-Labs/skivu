import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/device_task.dart';

Map<String, dynamic> observation() => {
  'package_name': 'org.example.notes',
  'observation_id': 'fresh',
  'service_instance_id': 'instance',
  'tree': {
    'elements': [
      {'element_id': '1', 'text': '便签内容'},
    ],
  },
};
String plan({
  bool done = false,
  String action = 'tap',
  Map<String, dynamic>? args,
  List<String>? evidence,
}) => jsonEncode({
  'done': done,
  'summary': '结果说明',
  'action': action,
  'arguments': args ?? {'element_id': '1'},
  'evidenceIds': evidence ?? [],
});
void main() {
  test(
    'only a terminal nonexecuted stale target permits bounded fresh planning',
    () async {
      int taps = 0, plans = 0, observes = 0;
      final states = <String>[];
      final ids = <String>[];
      final runner = DeviceTaskRunner(
        id: 'fresh',
        apps: {'org.example.notes'},
        maxActions: 6,
        maxRounds: 5,
        deadline: DateTime.now().add(const Duration(minutes: 1)),
        check: () {},
        waitForConfirmation: () async {},
        update: (s, _) async {
          states.add(s);
        },
        plan: (_, __) async {
          plans++;
          return plans < 3
              ? plan()
              : plan(done: true, action: '', args: {}, evidence: ['1']);
        },
        request: (method, args) async {
          if (method == 'begin') return {'taskCapability': 'lease'};
          if (method == 'end') return {};
          if (args['name'] == 'observe') {
            observes++;
            return observation();
          }
          if (args['name'] == 'tap') {
            taps++;
            ids.add((args['arguments'] as Map)['request_id']);
            if (taps == 1)
              return {
                'state': 'failed',
                'action_executed': false,
                'error': {'code': 'STALE_OBSERVATION', 'message': 'changed'},
              };
          }
          return {'state': 'executed', 'action_executed': true};
        },
      );
      await runner.run();
      expect(states.last, 'completed');
      expect(observes, 3);
      expect(ids.toSet().length, 2);
    },
  );
  test('planner cannot select a node not in the observation', () {
    expect(
      () => DevicePlan.parse(
        plan(args: {'element_id': 'invented'}),
        observation(),
        {'org.example.notes'},
      ),
      throwsA(isA<DeviceTaskFailure>()),
    );
  });
  test('planner cannot forge request identifiers or leave task app scope', () {
    expect(
      () => DevicePlan.parse(
        plan(args: {'element_id': '1', 'request_id': 'forged'}),
        observation(),
        {'org.example.notes'},
      ),
      throwsA(isA<DeviceTaskFailure>()),
    );
    expect(
      () => DevicePlan.parse(
        plan(action: 'launch_app', args: {'package_name': 'other.app'}),
        observation(),
        {'org.example.notes'},
      ),
      throwsA(isA<DeviceTaskFailure>()),
    );
  });
  test('completion requires evidence from the current screen', () {
    expect(
      () => DevicePlan.parse(
        plan(done: true, action: '', args: {}),
        observation(),
        {'org.example.notes'},
      ),
      throwsA(isA<DeviceTaskFailure>()),
    );
    expect(
      DevicePlan.parse(
        plan(done: true, action: '', args: {}, evidence: ['1']),
        observation(),
        {'org.example.notes'},
      ).done,
      isTrue,
    );
  });
  test('uncertain execution stops without resubmitting the action', () async {
    final calls = <String>[], states = <String>[];
    final runner = DeviceTaskRunner(
      id: 'test',
      apps: {'org.example.notes'},
      maxActions: 3,
      maxRounds: 3,
      deadline: DateTime.now().add(const Duration(minutes: 1)),
      check: () {},
      waitForConfirmation: () async {},
      update: (s, _) async {
        states.add(s);
      },
      plan: (_, __) async => plan(),
      request: (method, args) async {
        calls.add('$method:${args['name']}');
        if (method == 'begin') return {'taskCapability': 'lease'};
        if (method == 'end') return {};
        if (args['name'] == 'launch_app')
          return {'state': 'executed', 'action_executed': true};
        if (args['name'] == 'observe') return observation();
        return {'state': 'unknown', 'action_executed': null};
      },
    );
    await runner.run();
    expect(calls.where((c) => c == 'call:tap').length, 1);
    expect(states.last, 'review_required');
    expect(calls.last, 'end:null');
  });
  test('cancellation during planning prevents the proposed action', () async {
    late DeviceTaskRunner runner;
    int taps = 0;
    runner = DeviceTaskRunner(
      id: 'test',
      apps: {'org.example.notes'},
      maxActions: 3,
      maxRounds: 3,
      deadline: DateTime.now().add(const Duration(minutes: 1)),
      check: () {},
      waitForConfirmation: () async {},
      update: (_, __) async {},
      plan: (_, __) async {
        await runner.cancel();
        return plan();
      },
      request: (method, args) async {
        if (method == 'begin') return {'taskCapability': 'lease'};
        if (args['name'] == 'observe') return observation();
        if (args['name'] == 'tap') taps++;
        return {'state': 'executed', 'action_executed': true};
      },
    );
    await runner.run();
    expect(taps, 0);
  });
}

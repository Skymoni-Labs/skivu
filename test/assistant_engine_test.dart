import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/assistant_engine.dart';
import 'package:ski/device_engine.dart';

void main() {
  Map<String, dynamic> state = {};
  setUp(() => state = {'enabled': true, 'system': true});
  DeviceEngine native(
    Future<Map<String, dynamic>> Function(Map<String, dynamic>) call,
  ) => DeviceEngine(
    transport: (method, args) async => method == 'status' ? state : call(args),
  );
  AssistantEngine assistant(
    DeviceEngine engine,
    AssistantModel model, {
    AssistantWrite? write,
    AssistantRead? read,
    String Function()? identity,
  }) => AssistantEngine(
    engine: engine,
    model: model,
    identity: identity ?? () => 'model1',
    read: read ?? () async => null,
    write: write ?? (_) async {},
  );
  test(
    'model discovers interfaces, gets real receipt and uses isolated context',
    () async {
      var round = 0, calls = 0;
      final a = assistant(
        native((args) async {
          calls++;
          expect(args['owner'], startsWith('assistant:cloud_'));
          return {
            'requestId': args['requestId'],
            'outcome': 'verified',
            'summary': 'brightness 80',
            'value': {'level': 80},
          };
        }),
        (system, history) async {
          expect(system, contains('clock.alarm.create'));
          if (++round == 1)
            return '{"type":"call","tool":"settings.brightness.read","arguments":{},"message":"读取亮度"}';
          expect(history.last['content'], contains('brightness 80'));
          return '{"type":"final","message":"当前亮度80"}';
        },
      );
      await a.send('当前亮度是多少');
      expect(a.phase, 'done');
      expect(calls, 1);
      expect(a.messages.last['content'], '当前亮度80');
    },
  );
  test(
    'permission wait resumes the same operation ID without another model plan',
    () async {
      var granted = false, plans = 0;
      final ids = <String>[];
      final a = assistant(
        native((args) async {
          ids.add(args['requestId'] as String);
          return {
            'requestId': args['requestId'],
            'outcome': granted ? 'dispatched' : 'permission_required',
            'summary': 'clock',
          };
        }),
        (_, __) async => ++plans == 1
            ? '{"type":"call","tool":"clock.alarm.create","arguments":{"hour":8,"minute":15},"message":"设置闹钟"}'
            : '{"type":"final","message":"已派发，请核对时钟"}',
      );
      await a.send('8点15分闹钟');
      expect(a.canResume, true);
      expect(plans, 1);
      granted = true;
      await a.resume();
      expect(a.phase, 'awaiting_verification');
      expect(ids.length, 2);
      expect(ids[0], ids[1]);
    },
  );
  test(
    'uncertain writes never automatically replay, including after restart',
    () async {
      String? saved;
      var calls = 0;
      final a = assistant(
        native((args) async {
          calls++;
          return {
            'requestId': args['requestId'],
            'outcome': 'unknown',
            'summary': 'callback lost',
          };
        }),
        (_, __) async =>
            '{"type":"call","tool":"clock.alarm.create","arguments":{"hour":8,"minute":15},"message":"闹钟"}',
        write: (v) async => saved = v,
      );
      await a.send('闹钟');
      expect(a.phase, 'unknown');
      await a.resume();
      expect(calls, 1);
      final b = assistant(
        native((_) async => throw StateError('must not run')),
        (_, __) async => '',
        read: () async => saved,
      );
      await b.restore();
      expect(b.phase, 'unknown');
      expect(b.pending, isNull);
    },
  );
  test(
    'stop rejects late model output and a replacement connection cancels calls',
    () async {
      var identity = 'a', calls = 0;
      final reply = Completer<String>();
      final a = assistant(
        native((_) async {
          calls++;
          return {};
        }),
        (_, __) => reply.future,
        identity: () => identity,
      );
      final run = a.send('do something');
      await Future<void>.delayed(Duration.zero);
      identity = 'b';
      a.identityChanged();
      reply.complete(
        '{"type":"call","tool":"clock.alarms.show","arguments":{},"message":"show"}',
      );
      await run;
      await Future<void>.delayed(Duration.zero);
      expect(a.phase, 'stopped');
      expect(calls, 0);
      expect(a.pending, isNull);
    },
  );
  test('stop waits for its own request and retains uncertain shutdown', () async {
    final executing = Completer<void>(),
        stopped = Completer<Map<String, dynamic>>();
    final result = Completer<Map<String, dynamic>>();
    var invokes = 0, cancels = 0;
    late String ownedRequest;
    final a = assistant(
      DeviceEngine(
        transport: (method, args) async {
          if (method == 'status')
            return {'enabled': true, 'shell': true, 'shellConnected': true};
          if (method == 'invoke') {
            invokes++;
            ownedRequest = args['requestId'] as String;
            executing.complete();
            return result.future;
          }
          expect(method, 'cancelRequest');
          expect(args['owner'], startsWith('assistant:cloud_'));
          expect(args['requestId'], ownedRequest);
          cancels++;
          return stopped.future;
        },
      ),
      (_, __) async =>
          '{"type":"call","tool":"shell.execute","arguments":{"command":"sleep 45"},"message":"run"}',
    );
    final run = a.send('test stop');
    await executing.future;
    final stop = a.stop();
    final again = a.stop();
    await Future<void>.delayed(Duration.zero);
    expect(a.phase, 'stopping');
    await a.send('must not start while stopping');
    expect(invokes, 1);
    stopped.complete({'outcome': 'unknown'});
    await Future.wait([stop, again]);
    expect(cancels, 1);
    expect(a.phase, 'unknown');
    result.complete({
      'requestId': ownedRequest,
      'outcome': 'verified',
      'summary': 'late',
    });
    await run;
    expect(a.phase, 'unknown');
  });
  test('a journal failure cannot prevent an in-flight cancellation', () async {
    final started = Completer<void>(),
        result = Completer<Map<String, dynamic>>();
    var failSaving = false, cancelled = false;
    late String id;
    final a = assistant(
      DeviceEngine(
        transport: (method, args) async {
          if (method == 'status')
            return {'enabled': true, 'shell': true, 'shellConnected': true};
          if (method == 'invoke') {
            id = args['requestId'] as String;
            started.complete();
            return result.future;
          }
          expect(method, 'cancelRequest');
          cancelled = true;
          return {'outcome': 'cancelled'};
        },
      ),
      (_, __) async =>
          '{"type":"call","tool":"shell.execute","arguments":{"command":"sleep 45"},"message":"run"}',
      write: (_) async {
        if (failSaving) throw StateError('storage unavailable');
      },
    );
    final run = a.send('stop even when journal fails');
    await started.future;
    failSaving = true;
    await a.stop();
    expect(cancelled, true);
    expect(a.phase, 'stopped');
    result.complete({
      'requestId': id,
      'outcome': 'verified',
      'summary': 'late',
    });
    await run;
  });
  test('rejects forged ownership and invalid arguments before transport', () async {
    var calls = 0;
    final a = assistant(
      native((_) async {
        calls++;
        return {};
      }),
      (_, __) async =>
          '{"type":"call","tool":"clock.alarm.create","arguments":{"hour":"8","minute":0},"message":"clock"}',
    );
    await a.send('alarm');
    expect(calls, 0);
    expect(a.phase, 'unknown');
    expect(
      () => AssistantEngine.parse(
        '{"type":"call","tool":"ui.home","arguments":{},"message":"x","owner":"admin"}',
      ),
      throwsFormatException,
    );
  });
  test(
    'in-flight durable record restores as uncertain instead of executing',
    () async {
      final a = assistant(
        native((_) async => throw StateError('no')),
        (_, __) async => '',
        read: () async => jsonEncode({
          'version': 1,
          'messages': [],
          'goal': 'alarm',
          'taskId': 'cloud_1',
          'account': 'model1',
          'serial': 1,
          'phase': 'executing',
          'pending': {
            'tool': 'clock.alarms.show',
            'arguments': {},
            'requestId': 'cloud_1_1',
          },
        }),
      );
      await a.restore();
      expect(a.phase, 'unknown');
      expect(a.pending, isNull);
    },
  );
  test(
    'malformed model output is corrected before any external action',
    () async {
      var plans = 0, calls = 0;
      final a = assistant(
        native((args) async {
          calls++;
          return {
            'requestId': args['requestId'],
            'outcome': 'verified',
            'summary': 'read',
          };
        }),
        (_, history) async {
          plans++;
          if (plans == 1) return '{"type":"call"}<|DSML|parameter>';
          if (plans == 2) {
            expect(calls, 0);
            expect(history.last['content'], contains('没有派发'));
            return '{"type":"call","tool":"settings.brightness.read","arguments":{},"message":"read"}';
          }
          return '{"type":"final","message":"读取完成"}';
        },
      );
      await a.send('亮度');
      expect(a.phase, 'done');
      expect(calls, 1);
    },
  );
  test(
    'restart from the actual before-dispatch journal never replays and allows a new ordinary conversation',
    () async {
      String? durable;
      final dispatched = Completer<void>();
      final delayed = Completer<Map<String, dynamic>>();
      var originalCalls = 0, restoredCalls = 0, restoredPlans = 0;
      late String requestId;
      final original = assistant(
        native((args) {
          originalCalls++;
          requestId = args['requestId'] as String;
          final journal = jsonDecode(durable!) as Map;
          expect(journal['phase'], 'executing');
          expect(journal['pending']['requestId'], requestId);
          dispatched.complete();
          return delayed.future;
        }),
        (_, __) async =>
            '{"type":"call","tool":"shell.execute","arguments":{"command":"sleep 500"},"message":"Run once"}',
        write: (value) async => durable = value,
      );
      final firstRun = original.send('Run the controlled test once');
      await dispatched.future;
      final interruptedJournal = durable!;
      final restored = assistant(
        native((_) async {
          restoredCalls++;
          throw StateError('A restored write must never dispatch');
        }),
        (_, history) async {
          restoredPlans++;
          expect(history.last['content'], 'Just say hello without tools');
          return '{"type":"final","message":"Hello"}';
        },
        read: () async => interruptedJournal,
        write: (value) async => durable = value,
      );
      await restored.restore();
      await restored.resume();
      expect(restored.phase, 'unknown');
      expect(restored.pending, isNull);
      expect(restoredCalls, 0);
      expect(restoredPlans, 0);
      expect(restored.messages.last['content'], contains('不会自动重放'));
      await restored.send('Just say hello without tools');
      expect(restored.phase, 'done');
      expect(restored.messages.last['content'], 'Hello');
      expect(restoredCalls, 0);
      expect(restoredPlans, 1);
      expect(originalCalls, 1);
      delayed.complete({'requestId': requestId, 'outcome': 'unknown'});
      await firstRun;
      original.dispose();
      restored.dispose();
    },
  );
  test(
    'changing models during native execution cancels the original owner and rejects the late result',
    () async {
      var identity = 'first-model', plans = 0;
      Map<String, dynamic>? invocation, cancellation;
      final started = Completer<void>();
      final result = Completer<Map<String, dynamic>>();
      final cancelled = Completer<void>();
      final a = assistant(
        DeviceEngine(
          transport: (method, args) async {
            if (method == 'status') return state;
            if (method == 'invoke') {
              invocation = args;
              started.complete();
              return result.future;
            }
            expect(method, 'cancelRequest');
            cancellation = args;
            cancelled.complete();
            return {'outcome': 'cancelled'};
          },
        ),
        (_, __) async {
          plans++;
          return '{"type":"call","tool":"clock.alarms.show","arguments":{},"message":"Show clock"}';
        },
        identity: () => identity,
      );
      final run = a.send('Show my alarms');
      await started.future;
      identity = 'second-model';
      a.identityChanged();
      await cancelled.future;
      await a.stop();
      expect(cancellation?['owner'], invocation?['owner']);
      expect(cancellation?['requestId'], invocation?['requestId']);
      result.complete({
        'requestId': invocation!['requestId'],
        'outcome': 'verified',
        'summary': 'Late result must be discarded',
      });
      await run;
      expect(a.phase, 'stopped');
      expect(plans, 1);
      expect(a.pending, isNull);
      expect(
        a.messages.any(
          (message) => message['content']!.contains('Late result'),
        ),
        false,
      );
      a.dispose();
    },
  );
}

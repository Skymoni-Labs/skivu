import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ski/local_runtime_device_gateway.dart';
import 'package:ski/open_plugin.dart';
import 'package:ski/open_plugin_bridge.dart';

import 'open_plugin_test.dart' as fixture;

void main() {
  test('only explicitly granted device task methods reach the host', () async {
    final package = fixture.package(permissions: ['device.observe']);
    final registry = OpenPluginRegistry();
    final record = OpenPluginRecord(
      package,
      enabled: true,
      grantedDigest: package.digest,
    );
    registry.records[package.manifest.id] = record;
    final received = <String>[];
    final bridge = OpenPluginBridge(
      registry: registry,
      record: record,
      host: (method, _) async {
        received.add(method);
        return {'available': true};
      },
    );
    final gateway = LocalRuntimeDeviceGateway(bridge);
    var serial = 0;
    Future<Map> call(String method) async =>
        jsonDecode(
              await gateway.handle(
                jsonEncode({
                  'id': '${++serial}',
                  'method': method,
                  'params': {},
                }),
              ),
            )
            as Map;

    expect((await call('device.discover'))['ok'], true);
    expect(
      (await call('device.connect'))['error']['code'],
      'PERMISSION_DENIED',
    );
    for (final method in [
      'ai.generate',
      'network.request',
      'secrets.get',
      'appearance.apply',
      'host.info',
    ]) {
      expect((await call(method))['error']['code'], 'METHOD_NOT_FOUND');
    }
    expect(received, ['device.discover']);
    final replay = await gateway.handle(
      jsonEncode({'id': '1', 'method': 'device.discover', 'params': {}}),
    );
    expect((jsonDecode(replay) as Map)['error']['code'], 'DUPLICATE_REQUEST');
    expect(received, ['device.discover']);
    bridge.close();
    registry.dispose();
  });

  test('oversized or malformed frames never reach the host', () async {
    final package = fixture.package(permissions: ['device.observe']);
    final registry = OpenPluginRegistry();
    final record = OpenPluginRecord(
      package,
      enabled: true,
      grantedDigest: package.digest,
    );
    registry.records[package.manifest.id] = record;
    var calls = 0;
    final bridge = OpenPluginBridge(
      registry: registry,
      record: record,
      host: (_, __) async {
        calls++;
        return true;
      },
    );
    final gateway = LocalRuntimeDeviceGateway(bridge);
    expect(
      (jsonDecode(await gateway.handle('{broken')) as Map)['error']['code'],
      'INVALID_ARGUMENT',
    );
    final large = jsonEncode({
      'id': '1',
      'method': 'device.discover',
      'params': {'data': 'x' * 65536},
    });
    expect(
      (jsonDecode(await gateway.handle(large)) as Map)['error']['code'],
      'LIMIT_EXCEEDED',
    );
    expect(calls, 0);
    bridge.close();
    registry.dispose();
  });

  test('revocation discards a late host response', () async {
    final package = fixture.package(permissions: ['device.observe']);
    final registry = OpenPluginRegistry();
    final record = OpenPluginRecord(
      package,
      enabled: true,
      grantedDigest: package.digest,
    );
    registry.records[package.manifest.id] = record;
    final started = Completer<void>();
    final result = Completer<Object?>();
    final bridge = OpenPluginBridge(
      registry: registry,
      record: record,
      host: (_, __) {
        started.complete();
        return result.future;
      },
    );
    final gateway = LocalRuntimeDeviceGateway(bridge);
    final pending = gateway.handle(
      jsonEncode({'id': '5', 'method': 'device.discover', 'params': {}}),
    );
    await started.future;
    record.enabled = false;
    result.complete({'sensitive': 'must-not-return'});
    final response = jsonDecode(await pending) as Map;
    expect(response['error']['code'], 'CLOSED');
    expect(response.containsKey('result'), false);
    bridge.close();
    registry.dispose();
  });

  test(
    'stream transport handles split frames and preserves request order',
    () async {
      final package = fixture.package(permissions: ['device.observe']);
      final registry = OpenPluginRegistry();
      final record = OpenPluginRecord(
        package,
        enabled: true,
        grantedDigest: package.digest,
      );
      registry.records[package.manifest.id] = record;
      final calls = <String>[];
      final bridge = OpenPluginBridge(
        registry: registry,
        record: record,
        host: (method, params) async {
          calls.add(params['label'] as String);
          return {'label': params['label']};
        },
      );
      final gateway = LocalRuntimeDeviceGateway(bridge);
      final body = utf8.encode(
        [
          jsonEncode({
            'id': '1',
            'method': 'device.discover',
            'params': {'label': '手机'},
          }),
          jsonEncode({
            'id': '2',
            'method': 'device.discover',
            'params': {'label': 'second'},
          }),
          '',
        ].join('\n'),
      );
      final replies = <Map>[];
      final input = StreamController<List<int>>();
      final replied = Completer<void>();
      final served = gateway.serve(input.stream, (bytes) async {
        replies.add(jsonDecode(utf8.decode(bytes)) as Map);
        if (replies.length == 2) replied.complete();
      });
      input.add(body.sublist(0, 45));
      input.add(body.sublist(45));
      await replied.future;
      await input.close();
      await served;
      expect(calls, ['手机', 'second']);
      expect(replies.map((r) => r['id']), ['1', '2']);
      bridge.close();
      registry.dispose();
    },
  );

  test('disconnect requests cancellation of a started task', () async {
    final package = fixture.package(permissions: ['agent.tasks']);
    final registry = OpenPluginRegistry();
    final record = OpenPluginRecord(
      package,
      enabled: true,
      grantedDigest: package.digest,
    );
    registry.records[package.manifest.id] = record;
    final calls = <String>[];
    final bridge = OpenPluginBridge(
      registry: registry,
      record: record,
      host: (method, params) async {
        calls.add(method);
        if (method == 'agent.tasks.start')
          return {'taskId': 'fixture-task', 'state': 'running'};
        expect(params['taskId'], 'fixture-task');
        return {'taskId': 'fixture-task', 'state': 'cancelled'};
      },
    );
    final input = StreamController<List<int>>();
    final replied = Completer<void>();
    final gateway = LocalRuntimeDeviceGateway(bridge);
    final served = gateway.serve(input.stream, (_) async {
      replied.complete();
    });
    input.add(
      utf8.encode(
        '${jsonEncode({'id': '1', 'method': 'agent.tasks.start', 'params': {}})}\n',
      ),
    );
    await replied.future;
    await input.close();
    await served;
    expect(calls, ['agent.tasks.start', 'agent.tasks.cancel']);
    bridge.close();
    registry.dispose();
  });

  test('completed task is not cancelled on disconnect', () async {
    final package = fixture.package(permissions: ['agent.tasks']);
    final registry = OpenPluginRegistry();
    final record = OpenPluginRecord(
      package,
      enabled: true,
      grantedDigest: package.digest,
    );
    registry.records[package.manifest.id] = record;
    final calls = <String>[];
    final bridge = OpenPluginBridge(
      registry: registry,
      record: record,
      host: (method, _) async {
        calls.add(method);
        return {
          'taskId': 'fixture-task',
          'state': method == 'agent.tasks.start' ? 'running' : 'completed',
        };
      },
    );
    final gateway = LocalRuntimeDeviceGateway(bridge);
    final first = await gateway.handle(
      jsonEncode({'id': '1', 'method': 'agent.tasks.start', 'params': {}}),
    );
    final next = await gateway.handle(
      jsonEncode({
        'id': '2',
        'method': 'agent.tasks.get',
        'params': {'taskId': 'fixture-task'},
      }),
    );
    expect((jsonDecode(first) as Map)['ok'], true);
    expect((jsonDecode(next) as Map)['ok'], true);
    await gateway.close();
    expect(calls, ['agent.tasks.start', 'agent.tasks.get']);
    bridge.close();
    registry.dispose();
  });

  test(
    'a task started after disconnect is cancelled when its ID arrives',
    () async {
      final package = fixture.package(permissions: ['agent.tasks']);
      final registry = OpenPluginRegistry();
      final record = OpenPluginRecord(
        package,
        enabled: true,
        grantedDigest: package.digest,
      );
      registry.records[package.manifest.id] = record;
      final started = Completer<void>(),
          response = Completer<Object?>(),
          cancelled = Completer<void>();
      final bridge = OpenPluginBridge(
        registry: registry,
        record: record,
        host: (method, params) async {
          if (method == 'agent.tasks.start') {
            started.complete();
            return response.future;
          }
          expect(method, 'agent.tasks.cancel');
          expect(params['taskId'], 'late-task');
          cancelled.complete();
          return {'taskId': 'late-task', 'state': 'cancelled'};
        },
      );
      final input = StreamController<List<int>>();
      var replies = 0;
      final gateway = LocalRuntimeDeviceGateway(bridge);
      final served = gateway.serve(input.stream, (_) async {
        replies++;
      });
      input.add(
        utf8.encode(
          '${jsonEncode({'id': '1', 'method': 'agent.tasks.start', 'params': {}})}\n',
        ),
      );
      await started.future;
      await input.close();
      await served;
      response.complete({'taskId': 'late-task', 'state': 'running'});
      await cancelled.future;
      expect(replies, 0);
      bridge.close();
      registry.dispose();
    },
  );

  test(
    'stream transport closes on oversized, invalid UTF-8 or partial frames',
    () async {
      final package = fixture.package(permissions: ['device.observe']);
      final registry = OpenPluginRegistry();
      final record = OpenPluginRecord(
        package,
        enabled: true,
        grantedDigest: package.digest,
      );
      registry.records[package.manifest.id] = record;
      var calls = 0;
      final bridge = OpenPluginBridge(
        registry: registry,
        record: record,
        host: (_, __) async {
          calls++;
          return true;
        },
      );
      Future<void> run(List<int> data) => LocalRuntimeDeviceGateway(
        bridge,
      ).serve(Stream.value(data), (_) async {});
      await expectLater(run(List.filled(65537, 65)), throwsFormatException);
      await expectLater(run([0xff, 10]), throwsFormatException);
      await expectLater(run(utf8.encode('{')), throwsFormatException);
      expect(calls, 0);
      bridge.close();
      registry.dispose();
    },
  );
}

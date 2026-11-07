import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/device_engine.dart';
import 'package:ski/device_engine_plugin.dart';
import 'package:ski/local_runtime_device_gateway.dart';
import 'package:ski/open_plugin.dart';
import 'package:ski/open_plugin_bridge.dart';
import 'package:ski/open_plugin_network.dart';
import 'open_plugin_test.dart' as fixture;

void main() {
  (OpenPluginRegistry, OpenPluginRecord) setup(List<String> permissions) {
    final package = fixture.package(permissions: permissions);
    final registry = OpenPluginRegistry();
    final record = OpenPluginRecord(
      package,
      enabled: true,
      grantedDigest: package.digest,
    );
    registry.records[package.manifest.id] = record;
    addTearDown(registry.dispose);
    return (registry, record);
  }

  test(
    'a full normal broker queue still admits an owned Stop request',
    () async {
      final (registry, record) = setup(['device.observe']);
      final replies = <String, Completer<Map<String, dynamic>>>{};
      var nativeCalls = 0;
      final scope = DeviceEngineScope(
        engine: DeviceEngine(
          transport: (method, args) async {
            if (method == 'cancelRequest') {
              expect(args['owner'], devicePluginOwner(record));
              expect(args['requestId'], 'busy_0');
              replies['busy_0']!.complete({
                'requestId': 'busy_0',
                'outcome': 'unknown',
              });
              return {'outcome': 'cancelled', 'groupStopped': true};
            }
            expect(method, 'invoke');
            nativeCalls++;
            final id = args['requestId'] as String;
            return (replies[id] = Completer<Map<String, dynamic>>()).future;
          },
        ),
      );
      final bridge = OpenPluginBridge(
        registry: registry,
        record: record,
        host: (method, args) => scope.call(registry, record, method, args),
      );
      final requests = [
        for (var i = 0; i < 8; i++)
          bridge.dispatch({
            'id': '${i + 1}',
            'method': 'device.engine.invoke',
            'params': {
              'tool': 'settings.brightness.read',
              'arguments': <String, dynamic>{},
              'requestId': 'busy_$i',
            },
          }),
      ];
      await Future<void>.delayed(Duration.zero);
      expect(bridge.pending, 8);
      final extra = await bridge.dispatch({
        'id': '9',
        'method': 'device.engine.catalog',
        'params': <String, dynamic>{},
      });
      expect((extra['error'] as Map)['code'], 'BUSY');
      final stop = await bridge.dispatch({
        'id': '10',
        'method': 'device.engine.cancel',
        'params': {'requestId': 'busy_0'},
      });
      expect(stop['ok'], true);
      expect((stop['result'] as Map)['outcome'], 'cancelled');
      expect(nativeCalls, 8);
      for (var i = 1; i < 8; i++)
        replies['busy_$i']!.complete({
          'requestId': 'busy_$i',
          'outcome': 'verified',
        });
      await Future.wait(requests);
      expect(bridge.pending, 0);
      bridge.close();
    },
  );

  test(
    'a cancel frame bypasses a running DSH call and cannot target another scope',
    () async {
      final (registry, record) = setup(['device.observe']);
      final reply = Completer<Map<String, dynamic>>();
      final cancelled = Completer<void>();
      var cancellations = 0;
      final scope = DeviceEngineScope(
        engine: DeviceEngine(
          transport: (method, args) async {
            if (method == 'invoke') return reply.future;
            expect(method, 'cancelRequest');
            expect(args['owner'], devicePluginOwner(record));
            expect(args['requestId'], 'owned_read');
            cancellations++;
            cancelled.complete();
            reply.complete({
              'requestId': 'owned_read',
              'outcome': 'unknown',
              'summary': 'interrupted',
            });
            return {'outcome': 'cancelled'};
          },
        ),
      );
      final other = await scope.call(registry, record, 'device.engine.cancel', {
        'requestId': 'someone_else',
      });
      expect((other as Map)['outcome'], 'cancelled');
      expect(cancellations, 0);
      final bridge = OpenPluginBridge(
        registry: registry,
        record: record,
        host: (method, args) => scope.call(registry, record, method, args),
      );
      final gateway = LocalRuntimeDeviceGateway(bridge);
      final input = StreamController<List<int>>();
      final responses = <Map>[];
      final serving = gateway.serve(input.stream, (bytes) async {
        responses.add(jsonDecode(utf8.decode(bytes)) as Map);
      });
      input.add(
        utf8.encode(
          '${jsonEncode({
            'id': '1',
            'method': 'device.engine.invoke',
            'params': {'tool': 'settings.brightness.read', 'arguments': {}, 'requestId': 'owned_read'},
          })}\n${jsonEncode({
            'id': '2',
            'method': 'device.engine.cancel',
            'params': {'requestId': 'owned_read'},
          })}\n',
        ),
      );
      await cancelled.future.timeout(const Duration(seconds: 2));
      await Future<void>.delayed(Duration.zero);
      expect(cancellations, 1);
      expect(responses.map((r) => r['id']).toSet(), {'1', '2'});
      await input.close();
      await serving;
      scope.close();
      bridge.close();
    },
  );

  test(
    'a plugin cannot obtain system/shell access through a generic invoke method',
    () async {
      final (registry, record) = setup(['device.observe']);
      var calls = 0;
      final engine = DeviceEngine(
        transport: (_, args) async {
          calls++;
          return {'requestId': args['requestId'], 'outcome': 'verified'};
        },
      );
      for (final tool in ['clock.alarm.create', 'shell.execute', 'ui.tap']) {
        await expectLater(
          deviceEnginePluginCall(registry, record, 'device.engine.invoke', {
            'tool': tool,
            'arguments': <String, dynamic>{},
          }, engine: engine),
          throwsA(isA<PluginApiError>()),
        );
      }
      expect(calls, 0);
    },
  );

  test(
    'invalid native tool IDs and arguments return actionable bridge errors without dispatch',
    () async {
      final (registry, record) = setup(['device.shell']);
      var dispatched = 0;
      final engine = DeviceEngine(
        transport: (_, args) async {
          dispatched++;
          return {'requestId': args['requestId'], 'outcome': 'verified'};
        },
      );
      final bridge = OpenPluginBridge(
        registry: registry,
        record: record,
        host: (method, params) => deviceEnginePluginCall(
          registry,
          record,
          method,
          params,
          engine: engine,
        ),
      );
      for (final params in [
        {
          'tool': 'skivu_engine_invoke',
          'arguments': {'command': 'sleep 500', 'timeoutSeconds': 600},
        },
        {
          'tool': 'shell.execute',
          'arguments': {'command': 'id -u', 'timeout': 600},
        },
      ]) {
        final response = await bridge.dispatch({
          'id': '1',
          'method': 'device.engine.invoke',
          'params': params,
        });
        expect(response['ok'], false);
        expect((response['error'] as Map)['code'], 'INVALID_ARGUMENT');
        expect((response['error'] as Map)['message'], isNot('插件的宿主操作未完成。'));
      }
      expect(dispatched, 0);
      bridge.close();
    },
  );

  test('catalog exposes only the requesting plugin permissions', () async {
    final (registry, record) = setup(['device.observe', 'device.system']);
    final engine = DeviceEngine(
      transport: (_, args) async => {'enabled': true, 'system': true},
    );
    final result =
        await deviceEnginePluginCall(
              registry,
              record,
              'device.engine.catalog',
              {},
              engine: engine,
            )
            as Map;
    final ids = (result['tools'] as List).map((tool) => tool['id']);
    expect(ids, contains('clock.alarm.create'));
    expect(ids, isNot(contains('shell.execute')));
    expect(ids, isNot(contains('ui.tap')));
  });

  test(
    'ownership is derived from the granted package and cannot be forged',
    () async {
      final (registry, record) = setup(['device.system']);
      final seen = <Map<String, dynamic>>[];
      final engine = DeviceEngine(
        transport: (_, args) async {
          seen.add(args);
          return {'requestId': args['requestId'], 'outcome': 'dispatched'};
        },
      );
      await expectLater(
        deviceEnginePluginCall(registry, record, 'device.engine.invoke', {
          'tool': 'clock.alarms.show',
          'arguments': {},
          'owner': 'assistant',
        }, engine: engine),
        throwsA(isA<PluginApiError>()),
      );
      expect(seen, isEmpty);
      await deviceEnginePluginCall(registry, record, 'device.engine.invoke', {
        'tool': 'clock.alarms.show',
        'arguments': {},
        'requestId': 'clock_1',
      }, engine: engine);
      expect(seen.single['owner'], startsWith('plugin:'));
      expect(seen.single['owner'], isNot('assistant'));
      expect(seen.single['requestId'], 'clock_1');
    },
  );

  test(
    'late results are discarded after revocation, and future calls are refused',
    () async {
      final (registry, record) = setup(['device.system']);
      final started = Completer<void>();
      final result = Completer<Map<String, dynamic>>();
      final engine = DeviceEngine(
        transport: (_, args) {
          started.complete();
          return result.future;
        },
      );
      final call = deviceEnginePluginCall(
        registry,
        record,
        'device.engine.invoke',
        {
          'tool': 'clock.alarms.show',
          'arguments': {},
          'requestId': 'revoked_1',
        },
        engine: engine,
      );
      final rejected = expectLater(call, throwsA(isA<PluginApiError>()));
      await started.future;
      record.enabled = false;
      result.complete({'requestId': 'revoked_1', 'outcome': 'dispatched'});
      await rejected;
      await expectLater(
        deviceEnginePluginCall(
          registry,
          record,
          'device.engine.catalog',
          {},
          engine: engine,
        ),
        throwsA(isA<PluginApiError>()),
      );
    },
  );

  test(
    'DSH transport reaches the same permission-checked engine adapter',
    () async {
      final (registry, record) = setup(['device.system']);
      var count = 0;
      final engine = DeviceEngine(
        transport: (_, args) async {
          count++;
          return {'requestId': args['requestId'], 'outcome': 'dispatched'};
        },
      );
      final bridge = OpenPluginBridge(
        registry: registry,
        record: record,
        host: (method, params) => deviceEnginePluginCall(
          registry,
          record,
          method,
          params,
          engine: engine,
        ),
      );
      final gateway = LocalRuntimeDeviceGateway(bridge);
      final response =
          jsonDecode(
                await gateway.handle(
                  jsonEncode({
                    'id': '1',
                    'method': 'device.engine.invoke',
                    'params': {
                      'tool': 'clock.alarms.show',
                      'arguments': {},
                      'requestId': 'dsh_1',
                    },
                  }),
                ),
              )
              as Map;
      expect(response['ok'], true);
      expect(response['result']['outcome'], 'dispatched');
      expect(count, 1);
      await gateway.close();
      bridge.close();
    },
  );
}

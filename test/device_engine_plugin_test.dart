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

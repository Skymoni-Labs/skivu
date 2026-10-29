import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ski/chat_api.dart';
import 'package:ski/local_runtime_sessions.dart';
import 'package:ski/model_connection.dart';
import 'package:ski/open_plugin.dart';
import 'package:ski/open_plugin_bridge.dart';

import 'open_plugin_test.dart' as fixture;

void main() {
  final config = ModelConnection(
    id: 'fixture',
    name: 'fixture',
    provider: 'fixture',
    protocol: ApiProtocol.chat,
    address: 'unused',
    model: 'fixture',
  );
  AgentChatSession model() => AgentChatSession.account(
    MockClient((_) async => http.Response('{}', 200)),
    config,
    'synthetic',
  );
  final frame = jsonEncode({
    'id': '1',
    'method': 'device.discover',
    'params': {},
  });

  test(
    'a delayed close from an old runtime cannot close the replacement',
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
      OpenPluginBridge bridge() => OpenPluginBridge(
        registry: registry,
        record: record,
        host: (_, __) async {
          calls++;
          return true;
        },
      );
      final sessions = LocalRuntimeSessions();
      final first = await sessions.open(
        bridge: bridge(),
        confirmModel: () async => true,
        newModelSession: model,
      );
      expect(sessions.isActive(first), isTrue);
      final second = await sessions.open(
        bridge: bridge(),
        confirmModel: () async => true,
        newModelSession: model,
      );
      expect(sessions.isActive(first), isFalse);
      expect(sessions.isActive(second), isTrue);
      expect(second, greaterThan(first));
      await sessions.close(first);
      expect(
        (jsonDecode(await sessions.handle(first, 'device', frame))
            as Map)['error']['code'],
        'CLOSED',
      );
      expect(
        (jsonDecode(await sessions.handle(second, 'device', frame))
            as Map)['ok'],
        true,
      );
      expect(calls, 1);
      await sessions.dispose();
      expect(sessions.isActive(second), isFalse);
      registry.dispose();
    },
  );

  test('results arriving after a runtime is closed are not exposed', () async {
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
    final sessions = LocalRuntimeSessions();
    final generation = await sessions.open(
      bridge: bridge,
      confirmModel: () async => true,
      newModelSession: model,
    );
    final pending = sessions.handle(generation, 'device', frame);
    await started.future;
    await sessions.close(generation);
    result.complete({'value': 'late-private-result'});
    final response = await pending;
    expect(response, isNot(contains('late-private-result')));
    expect((jsonDecode(response) as Map)['error']['code'], 'CLOSED');
    await sessions.dispose();
    registry.dispose();
  });

  test('a late task start can be cancelled after its session closes', () async {
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
    final sessions = LocalRuntimeSessions();
    final generation = await sessions.open(
      bridge: bridge,
      confirmModel: () async => true,
      newModelSession: model,
    );
    final pending = sessions.handle(
      generation,
      'device',
      jsonEncode({'id': '1', 'method': 'agent.tasks.start', 'params': {}}),
    );
    await started.future;
    await sessions.close(generation);
    response.complete({'taskId': 'late-task', 'state': 'running'});
    await cancelled.future;
    expect((jsonDecode(await pending) as Map)['error']['code'], 'CLOSED');
    await Future<void>.delayed(Duration.zero);
    expect(bridge.closed, true);
    await sessions.dispose();
    registry.dispose();
  });

  test('disposed coordinator cannot reopen a runtime', () async {
    final package = fixture.package(permissions: ['device.observe']);
    final registry = OpenPluginRegistry();
    final record = OpenPluginRecord(
      package,
      enabled: true,
      grantedDigest: package.digest,
    );
    registry.records[package.manifest.id] = record;
    final bridge = OpenPluginBridge(
      registry: registry,
      record: record,
      host: (_, __) async => null,
    );
    final sessions = LocalRuntimeSessions();
    await sessions.dispose();
    await expectLater(
      sessions.open(
        bridge: bridge,
        confirmModel: () async => true,
        newModelSession: model,
      ),
      throwsStateError,
    );
    expect(bridge.closed, true);
    registry.dispose();
  });
}

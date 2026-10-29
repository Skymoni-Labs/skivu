import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ski/chat_api.dart';
import 'package:ski/local_runtime_model_gateway.dart';
import 'package:ski/model_connection.dart';
import 'package:ski/open_plugin.dart';
import 'package:ski/open_plugin_bridge.dart';

import 'open_plugin_test.dart' as fixture;

void main() {
  final config = ModelConnection(
    id: 'account',
    name: 'fixture',
    provider: 'fixture',
    protocol: ApiProtocol.chat,
    address: 'unused',
    model: 'host-selected',
  );
  String frame(
    String id,
    Map<String, Object> params, {
    String method = 'model.generate',
  }) => jsonEncode({'id': id, 'method': method, 'params': params});
  final params = <String, Object>{
    'messages': [
      {'role': 'user', 'content': 'hello'},
    ],
    'tools': <Object>[],
  };

  test('transport preserves split requests and stops at disconnect', () async {
    final package = fixture.package(permissions: ['ai.generate']);
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
    final sent = Completer<void>();
    final input = StreamController<List<int>>();
    final replies = <Map>[];
    final gateway = LocalRuntimeModelGateway(
      bridge: bridge,
      confirm: () async => true,
      newSession: () => AgentChatSession.account(
        MockClient(
          (_) async =>
              http.Response('{"choices":[{"message":{"content":"ok"}}]}', 200),
        ),
        config,
        'synthetic',
      ),
    );
    final done = gateway.serve(input.stream, (bytes) async {
      replies.add(jsonDecode(utf8.decode(bytes)) as Map);
      sent.complete();
    });
    final body = utf8.encode('${frame('1', params)}\n');
    input.add(body.sublist(0, 7));
    input.add(body.sublist(7));
    await sent.future;
    expect(replies.single['ok'], true);
    await input.close();
    await done;
    expect(
      (jsonDecode(await gateway.handle(frame('2', params)))
          as Map)['error']['code'],
      'CLOSED',
    );
    bridge.close();
    registry.dispose();
  });

  test(
    'disconnect during confirmation cancels before any model call',
    () async {
      final package = fixture.package(permissions: ['ai.generate']);
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
      final awaiting = Completer<void>(), confirmation = Completer<bool>();
      final input = StreamController<List<int>>();
      var requests = 0, replies = 0;
      final gateway = LocalRuntimeModelGateway(
        bridge: bridge,
        confirm: () {
          awaiting.complete();
          return confirmation.future;
        },
        newSession: () {
          requests++;
          return AgentChatSession.account(
            MockClient((_) async => http.Response('{}', 200)),
            config,
            'synthetic',
          );
        },
      );
      final done = gateway.serve(input.stream, (_) async {
        replies++;
      });
      input.add(utf8.encode('${frame('1', params)}\n'));
      await awaiting.future;
      await input.close();
      await done;
      confirmation.complete(true);
      await Future<void>.delayed(Duration.zero);
      expect(requests, 0);
      expect(replies, 0);
      bridge.close();
      registry.dispose();
    },
  );

  test('disconnect discards an in-flight result and queued request', () async {
    final package = fixture.package(permissions: ['ai.generate']);
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
    final started = Completer<void>();
    final response = Completer<http.Response>();
    final input = StreamController<List<int>>();
    var requests = 0, replies = 0;
    final gateway = LocalRuntimeModelGateway(
      bridge: bridge,
      confirm: () async => true,
      newSession: () => AgentChatSession.account(
        MockClient((_) {
          requests++;
          started.complete();
          return response.future;
        }),
        config,
        'synthetic',
      ),
    );
    final done = gateway.serve(input.stream, (_) async {
      replies++;
    });
    input.add(utf8.encode('${frame('1', params)}\n${frame('2', params)}\n'));
    await started.future;
    await input.close();
    await done;
    response.complete(
      http.Response('{"choices":[{"message":{"content":"late"}}]}', 200),
    );
    await Future<void>.delayed(Duration.zero);
    expect(requests, 1);
    expect(replies, 0);
    bridge.close();
    registry.dispose();
  });

  test('transport rejects a flood of queued frames before dispatch', () async {
    final package = fixture.package(permissions: ['ai.generate']);
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
    var confirms = 0;
    final gateway = LocalRuntimeModelGateway(
      bridge: bridge,
      confirm: () async {
        confirms++;
        return true;
      },
      newSession: () => throw StateError('unexpected model call'),
    );
    final input = StreamController<List<int>>();
    final done = gateway.serve(input.stream, (_) async {});
    final check = expectLater(done, throwsFormatException);
    input.add(
      utf8.encode(
        List.generate(9, (i) => frame('$i', params)).join('\n') + '\n',
      ),
    );
    await check;
    expect(confirms, 0);
    await input.close();
    bridge.close();
    registry.dispose();
  });

  test('transport rejects oversized frames before dispatch', () async {
    final package = fixture.package(permissions: ['ai.generate']);
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
    var confirms = 0;
    final gateway = LocalRuntimeModelGateway(
      bridge: bridge,
      confirm: () async {
        confirms++;
        return true;
      },
      newSession: () => throw StateError('unexpected model call'),
    );
    final input = StreamController<List<int>>();
    final done = gateway.serve(input.stream, (_) async {});
    final check = expectLater(done, throwsFormatException);
    input.add(List.filled(LocalRuntimeModelGateway.maxFrameBytes, 65));
    input.add([65]);
    await check;
    expect(confirms, 0);
    await input.close();
    bridge.close();
    registry.dispose();
  });

  test('permission and confirmation precede any model request', () async {
    final package = fixture.package(permissions: ['storage']);
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
    var confirms = 0, requests = 0;
    final gateway = LocalRuntimeModelGateway(
      bridge: bridge,
      confirm: () async {
        confirms++;
        return true;
      },
      newSession: () => AgentChatSession.account(
        MockClient((_) async {
          requests++;
          return http.Response('{}', 200);
        }),
        config,
        'synthetic',
      ),
    );
    final reply = jsonDecode(await gateway.handle(frame('1', params))) as Map;
    expect(reply['error']['code'], 'PERMISSION_DENIED');
    expect(confirms, 0);
    expect(requests, 0);
    bridge.close();
    registry.dispose();
  });

  test(
    'model override is rejected and confirmation denial makes no network request',
    () async {
      final package = fixture.package(permissions: ['ai.generate']);
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
      var confirms = 0, requests = 0;
      final gateway = LocalRuntimeModelGateway(
        bridge: bridge,
        confirm: () async {
          confirms++;
          return false;
        },
        newSession: () => AgentChatSession.account(
          MockClient((_) async {
            requests++;
            return http.Response('{}', 200);
          }),
          config,
          'synthetic',
        ),
      );
      var reply =
          jsonDecode(
                await gateway.handle(
                  frame('1', {...params, 'model': 'override'}),
                ),
              )
              as Map;
      expect(reply['error']['code'], 'INVALID_ARGUMENT');
      reply = jsonDecode(await gateway.handle(frame('2', params))) as Map;
      expect(reply['error']['code'], 'CANCELLED');
      expect(confirms, 1);
      expect(requests, 0);
      bridge.close();
      registry.dispose();
    },
  );

  test('revocation discards an in-flight response', () async {
    final package = fixture.package(permissions: ['ai.generate']);
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
    final started = Completer<void>(), response = Completer<http.Response>();
    final gateway = LocalRuntimeModelGateway(
      bridge: bridge,
      confirm: () async => true,
      newSession: () => AgentChatSession.account(
        MockClient((_) {
          started.complete();
          return response.future;
        }),
        config,
        'synthetic',
      ),
    );
    final pending = gateway.handle(frame('1', params));
    await started.future;
    record.enabled = false;
    registry.storageChanged(package.manifest.id);
    response.complete(
      http.Response('{"choices":[{"message":{"content":"late"}}]}', 200),
    );
    final reply = jsonDecode(await pending) as Map;
    expect(reply['error']['code'], 'CLOSED');
    expect(reply.containsKey('result'), false);
    bridge.close();
    registry.dispose();
  });

  test(
    'confirmed request returns structured tool calls without credentials or replay',
    () async {
      final package = fixture.package(permissions: ['ai.generate']);
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
      var calls = 0;
      final gateway = LocalRuntimeModelGateway(
        bridge: bridge,
        confirm: () async => true,
        newSession: () => AgentChatSession.account(
          MockClient((request) async {
            calls++;
            expect(jsonDecode(request.body)['model'], 'host-selected');
            return http.Response(
              '{"choices":[{"finish_reason":"tool_calls","message":{"tool_calls":[{"id":"call_1"}]}}]}',
              200,
            );
          }),
          config,
          'private-synthetic-token',
        ),
      );
      final result = await gateway.handle(frame('1', params));
      expect(result, isNot(contains('private-synthetic-token')));
      expect(
        (jsonDecode(result) as Map)['result']['choices'][0]['finish_reason'],
        'tool_calls',
      );
      expect(
        (jsonDecode(await gateway.handle(frame('1', params)))
            as Map)['error']['code'],
        'DUPLICATE_REQUEST',
      );
      expect(calls, 1);
      bridge.close();
      registry.dispose();
    },
  );

  test('closed runtime cannot start or receive model requests', () async {
    final package = fixture.package(permissions: ['ai.generate']);
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
    final started = Completer<void>(), response = Completer<http.Response>();
    final gateway = LocalRuntimeModelGateway(
      bridge: bridge,
      confirm: () async => true,
      newSession: () => AgentChatSession.account(
        MockClient((_) {
          started.complete();
          return response.future;
        }),
        config,
        'synthetic',
      ),
    );
    final pending = gateway.handle(frame('1', params));
    await started.future;
    gateway.close();
    response.complete(
      http.Response('{"choices":[{"message":{"content":"late"}}]}', 200),
    );
    expect((jsonDecode(await pending) as Map)['error']['code'], 'CLOSED');
    expect(
      (jsonDecode(await gateway.handle(frame('2', params)))
          as Map)['error']['code'],
      'CLOSED',
    );
    bridge.close();
    registry.dispose();
  });
}

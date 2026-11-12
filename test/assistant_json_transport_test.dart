import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ski/assistant_engine.dart';
import 'package:ski/chat_api.dart';
import 'package:ski/device_engine.dart';
import 'package:ski/model_connection.dart';
import 'package:ski/state.dart';

import 'real_chat_store_test.dart' show MemoryChats, TestModels;

ModelConnection config({bool? thinking, String model = 'deepseek-flash'}) =>
    ModelConnection(
      id: 'json-fixture',
      name: 'JSON fixture',
      provider: '自定义兼容接口',
      protocol: ApiProtocol.chat,
      address: 'https://api.deepseek.com/v1',
      model: model,
      streaming: false,
      thinkingEnabled: thinking,
    );

http.Response response({String content = '{}', String finish = 'stop'}) =>
    http.Response(
      jsonEncode({
        'choices': [
          {
            'message': {'content': content},
            'finish_reason': finish,
          },
        ],
      }),
      200,
      headers: {'content-type': 'application/json'},
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'requested JSON output is independent of the thinking preference',
    () async {
      for (final model in ['deepseek-flash', 'deepseek-v4-pro']) {
        for (final thinking in [null, false, true]) {
          final api = ChatApi(
            clientFactory: () => MockClient((request) async {
              final body = jsonDecode(request.body) as Map;
              expect(body['response_format'], {'type': 'json_object'});
              expect(
                body['thinking'],
                thinking == null
                    ? null
                    : {'type': thinking ? 'enabled' : 'disabled'},
              );
              return response();
            }),
          );
          await api
              .start(
                config(thinking: thinking, model: model),
                'fixture',
                [],
                'Return one JSON object.',
                jsonOutput: true,
              )
              .events
              .toList();
        }
      }
    },
  );

  test(
    'ordinary chat keeps its four argument API and free text response',
    () async {
      final api = ChatApi(
        clientFactory: () => MockClient((request) async {
          expect(
            (jsonDecode(request.body) as Map).containsKey('response_format'),
            isFalse,
          );
          return response(content: 'ordinary text');
        }),
      );
      final events = await api
          .start(config(), 'fixture', [], 'Hello')
          .events
          .toList();
      expect(events.single.text, 'ordinary text');
    },
  );

  test(
    'unknown services models and protocols receive no JSON extension',
    () async {
      for (final overrides in [
        {'address': 'https://models.example/v1', 'provider': 'DeepSeek'},
        {'address': 'https://api.deepseek.com.example/v1'},
        {'address': 'https://api.deepseek.com:8443/v1'},
        {'model': 'unknown-model'},
        {'protocol': 'responses'},
      ]) {
        final profile = ModelConnection.fromJson({
          ...config().toJson(),
          ...overrides,
        });
        final api = ChatApi(
          clientFactory: () => MockClient((request) async {
            expect(
              (jsonDecode(request.body) as Map).containsKey('response_format'),
              isFalse,
            );
            return response();
          }),
        );
        await api
            .start(profile, 'fixture', [], 'Return JSON.', jsonOutput: true)
            .events
            .toList();
      }
    },
  );

  test('account and beta transport retain their accepted payloads', () async {
    MockClient client() => MockClient((request) async {
      final body = jsonDecode(request.body) as Map;
      expect(body.containsKey('response_format'), isFalse);
      expect(body.containsKey('thinking'), isFalse);
      return response();
    });
    await ChatSession.account(
      client(),
      config(thinking: false),
      [],
      'JSON',
      'token',
    ).events.toList();
    await ChatSession.beta(
      client(),
      config(thinking: true),
      [],
      'JSON',
      (_) async => {},
    ).events.toList();
  });

  test(
    'assistant and device planner entry points request JSON output',
    () async {
      final models = TestModels();
      addTearDown(models.dispose);
      models.connections
        ..clear()
        ..add(config(thinking: false));
      models.activeId = models.connections.single.id;
      var requests = 0;
      final store = DemoStore(
        settings: models,
        storage: MemoryChats(),
        api: ChatApi(
          clientFactory: () => MockClient((request) async {
            requests++;
            final body = jsonDecode(request.body) as Map;
            expect(body['response_format'], {'type': 'json_object'});
            expect(body['thinking'], {'type': 'disabled'});
            return response();
          }),
        ),
      );
      addTearDown(store.dispose);
      final assistant = await store.startAssistantReply('Return JSON.', []);
      expect(assistant.jsonOutput, isTrue);
      await assistant.events.toList();
      final device = await store.startDeviceReply('Observe this fixture.', 512);
      expect(device.jsonOutput, isTrue);
      await device.events.toList();
      expect(requests, 2);
    },
  );

  test(
    'blank and truncated JSON planner responses dispatch zero actions',
    () async {
      for (final finish in ['stop', 'length']) {
        var actions = 0;
        final engine = AssistantEngine(
          identity: () => 'fixture',
          read: () async => null,
          write: (_) async {},
          engine: DeviceEngine(
            transport: (method, args) async {
              if (method == 'invoke') actions++;
              return {'enabled': true};
            },
          ),
          model: (system, history) async {
            final api = ChatApi(
              clientFactory: () => MockClient(
                (_) async => response(
                  content: finish == 'stop' ? '   ' : '{"type":"call"',
                  finish: finish,
                ),
              ),
            );
            final session = api.start(
              config(),
              'fixture',
              history,
              system,
              jsonOutput: true,
            );
            final events = await session.events.toList();
            if (events.any((event) => event.limited))
              throw AssistantOutputLimit(512);
            return events.map((event) => event.text).join();
          },
        );
        await engine.send('Read the current fixture.');
        expect(engine.phase, 'failed');
        expect(actions, 0);
        expect(
          engine.modelResponseIssues.every(
            (issue) =>
                issue['kind'] ==
                (finish == 'length' ? 'output_limit' : 'invalid_action'),
          ),
          isTrue,
        );
        engine.dispose();
      }
    },
  );
}

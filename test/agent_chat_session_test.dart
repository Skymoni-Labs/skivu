import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ski/chat_api.dart';
import 'package:ski/model_connection.dart';

ModelConnection config({ApiProtocol protocol = ApiProtocol.chat}) =>
    ModelConnection(
      id: 'account',
      name: 'fixture',
      provider: 'fixture',
      protocol: protocol,
      address: 'https://ignored.example',
      model: 'host-selected',
      maxOutput: 5000,
    );

void main() {
  test(
    'nonstream coding response preserves content beyond the former 4 MiB gate',
    () async {
      final text = '完整代码🙂' * 600000;
      final session = AgentChatSession.account(
        MockClient(
          (_) async => http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'role': 'assistant', 'content': text},
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ),
        ),
        config(),
        'fixture-token',
      );
      addTearDown(session.cancel);
      final value = await session.send(
        messages: [
          {'role': 'user', 'content': '生成代码'},
        ],
        tools: [],
      );
      expect(value['choices'][0]['message']['content'], text);
    },
  );
  test('host does not impose message or tool count caps', () async {
    var sent = 0;
    final session = AgentChatSession.account(
      MockClient((request) async {
        sent++;
        return http.Response('{"choices":[{"message":{"content":"ok"}}]}', 200);
      }),
      config(),
      'synthetic',
    );
    await session.send(
      messages: List.generate(3000, (_) => {'role': 'user', 'content': 'hi'}),
      tools: List.generate(
        300,
        (i) => {
          'type': 'function',
          'function': {
            'name': 'tool_$i',
            'parameters': {'type': 'object'},
          },
        },
      ),
    );
    expect(sent, 1);
  });
  test(
    'long programming requests cross former message tool and byte limits',
    () async {
      var sent = 0;
      final session = AgentChatSession.account(
        MockClient((request) async {
          sent++;
          final body = jsonDecode(request.body) as Map;
          expect((body['messages'] as List).length, 300);
          expect((body['tools'] as List).length, 96);
          expect(utf8.encode(request.body).length, greaterThan(256 * 1024));
          return http.Response(
            '{"choices":[{"message":{"content":"ok"}}]}',
            200,
          );
        }),
        config(),
        'synthetic-token',
      );
      await session.send(
        messages: List.generate(
          300,
          (_) => {'role': 'user', 'content': 'history ' * 128},
        ),
        tools: List.generate(
          96,
          (i) => {
            'type': 'function',
            'function': {
              'name': 'tool_$i',
              'description': 'description ' * 100,
              'parameters': {'type': 'object'},
            },
          },
        ),
      );
      expect(sent, 1);
    },
  );
  test(
    'account agent request preserves tool calls and keeps selection and credentials in host',
    () async {
      final client = MockClient((request) async {
        expect(
          request.url.toString(),
          'https://skymoni.com/api/app-account/agent/chat/completions',
        );
        expect(request.headers['authorization'], 'AppAccount synthetic-token');
        final body = jsonDecode(request.body) as Map;
        expect(body['model'], 'host-selected');
        expect(body['max_tokens'], 5000);
        expect(body['funding'], 'beta');
        expect(body['stream'], false);
        expect((body['tools'] as List).first['function']['name'], 'write_file');
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'role': 'assistant',
                  'tool_calls': [
                    {
                      'id': 'call_1',
                      'type': 'function',
                      'function': {
                        'name': 'write_file',
                        'arguments': '{"path":"a"}',
                      },
                    },
                  ],
                },
                'finish_reason': 'tool_calls',
              },
            ],
            'usage': {'prompt_tokens': 10, 'completion_tokens': 5},
            'internal': 'ignored',
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final session = AgentChatSession.account(
        client,
        config(),
        'synthetic-token',
        funding: 'beta',
      );
      final result = await session.send(
        messages: [
          {'role': 'user', 'content': 'write'},
        ],
        tools: [
          {
            'type': 'function',
            'function': {
              'name': 'write_file',
              'parameters': {'type': 'object'},
            },
          },
        ],
      );
      expect(result['choices'][0]['message']['tool_calls'][0]['id'], 'call_1');
      expect(result['usage']['completion_tokens'], 5);
      expect(result.containsKey('internal'), false);
      await expectLater(
        session.send(messages: [], tools: []),
        throwsA(isA<ChatFailure>()),
      );
    },
  );

  test(
    'unpublished models preserve the known error and unsupported protocol never sends',
    () async {
      var calls = 0;
      final unavailable = AgentChatSession.account(
        MockClient((_) async {
          calls++;
          return http.Response('{"code":"model_not_available"}', 404);
        }),
        config(),
        'synthetic-token',
      );
      await expectLater(
        unavailable.send(
          messages: [
            {'role': 'user', 'content': 'hi'},
          ],
          tools: [],
        ),
        throwsA(
          isA<ChatFailure>().having(
            (e) => e.code,
            'code',
            'model_not_available',
          ),
        ),
      );
      final wrongProtocol = AgentChatSession.account(
        MockClient((_) async {
          calls++;
          return http.Response('{}', 200);
        }),
        config(protocol: ApiProtocol.responses),
        'synthetic-token',
      );
      await expectLater(
        wrongProtocol.send(
          messages: [
            {'role': 'user', 'content': 'hi'},
          ],
          tools: [],
        ),
        throwsA(isA<ChatFailure>()),
      );
      expect(calls, 1);
    },
  );

  test(
    'large valid requests reach the network without the former four MiB quota',
    () async {
      var calls = 0;
      final session = AgentChatSession.account(
        MockClient((request) async {
          calls++;
          expect(
            utf8.encode(request.body).length,
            greaterThan(4 * 1024 * 1024),
          );
          return http.Response(
            '{"choices":[{"message":{"content":"ok"}}]}',
            200,
          );
        }),
        config(),
        'synthetic-token',
      );
      final result = await session.send(
        messages: [
          {'role': 'user', 'content': 'x' * (4 * 1024 * 1024)},
        ],
        tools: [],
      );
      expect(result['choices'][0]['message']['content'], 'ok');
      expect(calls, 1);
    },
  );
}

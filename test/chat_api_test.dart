import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ski/chat_api.dart';
import 'package:ski/model_connection.dart';

ModelConnection connection(
  ApiProtocol protocol, {
  bool streaming = true,
  String address = 'https://models.example/prefix/v1',
  int timeout = 120,
}) => ModelConnection(
  id: 'test',
  name: '测试',
  provider: '测试服务',
  protocol: protocol,
  address: address,
  model: protocol == ApiProtocol.gemini ? 'gemini-test' : 'test-model',
  streaming: streaming,
  timeoutSeconds: timeout,
);

String sse(List<Object> frames) =>
    '${frames.map((f) => 'data: ${f is String ? f : jsonEncode(f)}\r\n\r\n').join()}';
Stream<List<int>> fragmented(String source) async* {
  // Splitting inside Chinese UTF-8 code points exercises incremental decoding.
  final bytes = utf8.encode(source);
  for (var i = 0; i < bytes.length; i += 3) {
    yield bytes.sublist(i, (i + 3).clamp(0, bytes.length));
  }
}

void main() {
  test('endpoints preserve reverse-proxy prefixes, full paths and Azure query', () {
    expect(
      connection(ApiProtocol.chat).endpoint().toString(),
      'https://models.example/prefix/v1/chat/completions',
    );
    final c = connection(
      ApiProtocol.chat,
      address:
          'https://models.example/openai/deployments/chat/chat/completions?api-version=2024-10-21',
    );
    expect(c.endpoint().toString(), c.address);
    expect(
      connection(
        ApiProtocol.responses,
        address: 'https://models.example/v1/responses',
      ).endpoint().path,
      '/v1/responses',
    );
    expect(
      connection(
        ApiProtocol.gemini,
        address: 'https://models.example/v1beta',
      ).endpoint().toString(),
      'https://models.example/v1beta/models/gemini-test:streamGenerateContent?alt=sse',
    );
    expect(
      () => connection(
        ApiProtocol.chat,
        address: 'https://models.example/v1?api_key=secret',
      ).endpoint(),
      throwsFormatException,
    );
    expect(
      () => connection(ApiProtocol.chat, address: 'file:///local').endpoint(),
      throwsFormatException,
    );
  });

  final streamingFrames = <ApiProtocol, List<Object>>{
    ApiProtocol.chat: [
      {
        'choices': [
          {
            'delta': {'content': '你好，'},
            'finish_reason': null,
          },
        ],
      },
      {
        'choices': [
          {
            'delta': {'content': '世界'},
            'finish_reason': 'stop',
          },
        ],
      },
      {
        'choices': [],
        'usage': {
          'prompt_tokens': 20,
          'completion_tokens': 4,
          'prompt_tokens_details': {'cached_tokens': 10},
        },
      },
      '[DONE]',
    ],
    ApiProtocol.responses: [
      {'type': 'response.output_text.delta', 'delta': '你好，'},
      {'type': 'response.output_text.delta', 'delta': '世界'},
      {
        'type': 'response.completed',
        'response': {
          'status': 'completed',
          'usage': {
            'input_tokens': 20,
            'output_tokens': 4,
            'input_tokens_details': {'cached_tokens': 10},
          },
        },
      },
    ],
    ApiProtocol.anthropic: [
      {
        'type': 'message_start',
        'message': {
          'usage': {
            'input_tokens': 10,
            'cache_read_input_tokens': 10,
            'output_tokens': 0,
          },
        },
      },
      {
        'type': 'content_block_delta',
        'delta': {'type': 'text_delta', 'text': '你好，'},
      },
      {
        'type': 'content_block_delta',
        'delta': {'type': 'text_delta', 'text': '世界'},
      },
      {
        'type': 'message_delta',
        'usage': {'output_tokens': 4},
      },
      {'type': 'message_stop'},
    ],
    ApiProtocol.gemini: [
      {
        'candidates': [
          {
            'content': {
              'parts': [
                {'text': '你好，'},
              ],
            },
          },
        ],
      },
      {
        'candidates': [
          {
            'content': {
              'parts': [
                {'text': '世界'},
              ],
            },
            'finishReason': 'STOP',
          },
        ],
        'usageMetadata': {
          'promptTokenCount': 20,
          'candidatesTokenCount': 4,
          'cachedContentTokenCount': 10,
        },
      },
    ],
  };
  for (final protocol in ApiProtocol.values) {
    test(
      '${protocol.name} sends real history, authenticates and decodes fragmented SSE',
      () async {
        Map<String, dynamic>? body;
        final api = ChatApi(
          clientFactory: () => MockClient.streaming((request, bytes) async {
            body =
                jsonDecode(await bytes.bytesToString()) as Map<String, dynamic>;
            if (protocol == ApiProtocol.anthropic) {
              expect(request.headers['x-api-key'], 'test-key-only');
              expect(request.headers['anthropic-version'], '2023-06-01');
            } else if (protocol == ApiProtocol.gemini) {
              expect(request.headers['x-goog-api-key'], 'test-key-only');
            } else {
              expect(request.headers['Authorization'], 'Bearer test-key-only');
            }
            return http.StreamedResponse(
              fragmented(': ping\r\n\r\n${sse(streamingFrames[protocol]!)}'),
              200,
              headers: {'content-type': 'text/event-stream'},
            );
          }),
        );
        var usage = const ApiUsage();
        final text = StringBuffer();
        var done = false;
        await for (final event in api.start(
          connection(protocol),
          'test-key-only',
          [
            {'role': 'user', 'content': '第一轮'},
            {'role': 'assistant', 'content': '收到'},
            {'role': 'user', 'content': '继续'},
          ],
          '角色设定',
        ).events) {
          text.write(event.text);
          done |= event.done;
          if (event.usage != null) usage = usage.merge(event.usage!);
        }
        expect(text.toString(), '你好，世界');
        expect(done, isTrue);
        expect([usage.input, usage.output, usage.cached], [20, 4, 10]);
        expect(jsonEncode(body), contains('第一轮'));
        expect(jsonEncode(body), contains('角色设定'));
        if (protocol == ApiProtocol.responses) expect(body!['store'], false);
        if (protocol == ApiProtocol.chat) expect(body!['max_tokens'], 2048);
      },
    );
  }

  final fullReplies = <ApiProtocol, Map<String, dynamic>>{
    ApiProtocol.chat: {
      'choices': [
        {
          'message': {'content': '完整回复'},
          'finish_reason': 'stop',
        },
      ],
    },
    ApiProtocol.responses: {
      'status': 'completed',
      'output': [
        {
          'type': 'message',
          'content': [
            {'type': 'output_text', 'text': '完整回复'},
          ],
        },
      ],
    },
    ApiProtocol.anthropic: {
      'content': [
        {'type': 'text', 'text': '完整回复'},
      ],
      'stop_reason': 'end_turn',
    },
    ApiProtocol.gemini: {
      'candidates': [
        {
          'content': {
            'parts': [
              {'text': '完整回复'},
            ],
          },
          'finishReason': 'STOP',
        },
      ],
    },
  };
  for (final protocol in ApiProtocol.values) {
    test('${protocol.name} handles non-streaming JSON', () async {
      final api = ChatApi(
        clientFactory: () => MockClient(
          (r) async => http.Response(
            jsonEncode(fullReplies[protocol]),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ),
        ),
      );
      final events = await api
          .start(connection(protocol, streaming: false), 'test', [
            {'role': 'user', 'content': '你好'},
          ], '')
          .events
          .toList();
      expect(events.single.text, '完整回复');
      expect(events.single.done, isTrue);
    });
  }

  test(
    'HTTP errors never expose response bodies, request addresses or keys',
    () async {
      final api = ChatApi(
        clientFactory: () => MockClient(
          (r) async => http.Response('test-key-only internal details', 401),
        ),
      );
      try {
        await api
            .start(connection(ApiProtocol.chat), 'test-key-only', [], '')
            .events
            .toList();
        fail('must fail');
      } on ChatFailure catch (e) {
        expect(e.message, contains('鉴权失败'));
        expect(e.message, isNot(contains('test-key-only')));
      }
    },
  );

  test(
    'truncated SSE reports an error after preserving received text',
    () async {
      final api = ChatApi(
        clientFactory: () => MockClient.streaming(
          (r, b) async => http.StreamedResponse(
            fragmented(
              sse([
                {
                  'choices': [
                    {
                      'delta': {'content': '保留'},
                    },
                  ],
                },
              ]),
            ),
            200,
          ),
        ),
      );
      final received = <String>[];
      await expectLater(
        api
            .start(connection(ApiProtocol.chat), 'test', [], '')
            .events
            .forEach((e) => received.add(e.text)),
        throwsA(isA<ChatFailure>()),
      );
      expect(received.join(), '保留');
    },
  );

  test(
    'SSE error and malformed data cannot be reported as successful replies',
    () async {
      for (final payload in [
        sse([
          {
            'type': 'error',
            'error': {'message': 'private'},
          },
        ]),
        'data: {broken}\n\n',
      ]) {
        final api = ChatApi(
          clientFactory: () => MockClient.streaming(
            (r, b) async => http.StreamedResponse(fragmented(payload), 200),
          ),
        );
        await expectLater(
          api
              .start(connection(ApiProtocol.chat), 'test', [], '')
              .events
              .drain<void>(),
          throwsA(isA<ChatFailure>()),
        );
      }
    },
  );

  test('model listing supports both compatible and Gemini schemas', () async {
    for (final raw in [
      {
        'data': [
          {'id': 'a'},
          {'id': 'b'},
        ],
      },
      {
        'models': [
          {'name': 'models/a'},
          {'name': 'models/b'},
        ],
      },
    ]) {
      final api = ChatApi(
        clientFactory: () => MockClient((r) async {
          expect(r.followRedirects, isFalse);
          return http.Response(jsonEncode(raw), 200);
        }),
      );
      expect(await api.models(connection(ApiProtocol.chat), 'test'), [
        'a',
        'b',
      ]);
    }
  });
}

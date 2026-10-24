import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ski/chat_api.dart';
import 'package:ski/model_connection.dart';

ModelConnection config(
  ApiProtocol p, {
  int? limit,
  String address = 'https://example.test/v1',
}) => ModelConnection(
  id: 'x',
  name: 'x',
  provider: 'x',
  protocol: p,
  address: address,
  model: 'x',
  streaming: false,
  maxOutput: 64,
  contextLimit: limit,
);
void main() {
  for (final protocol in ApiProtocol.values) {
    test(
      '$protocol prunes complete old turns and preserves Chinese latest input',
      () async {
        String? sent;
        final history = <Map<String, String>>[
          for (var i = 0; i < 150; i++) ...[
            {'role': 'user', 'content': '旧问题$i'},
            {'role': 'assistant', 'content': '旧回答$i'},
          ],
          {'role': 'user', 'content': '当前问题中文'},
          {'role': 'user', 'content': '本轮第二项'},
        ];
        final original = jsonEncode(history);
        final client = MockClient((r) async {
          sent = r.body;
          return http.Response(
            '{}',
            200,
            headers: {'content-type': 'application/json'},
          );
        });
        final events = await ChatSession(
          client,
          config(protocol, limit: 450),
          '',
          history,
          '必须保留角色设定',
        ).events.toList();
        expect(events.first.notice, contains('本地记录完整保留'));
        expect(sent, contains('当前问题中文'));
        expect(sent, contains('本轮第二项'));
        expect(sent, contains('必须保留角色设定'));
        expect(sent, isNot(contains('旧问题0"')));
        expect(jsonEncode(history), original);
      },
    );
    test('$protocol preserves nested unavailable errors', () async {
      for (final status in [200, 403]) {
        final client = MockClient(
          (r) async => http.Response(
            jsonEncode({
              'response': {
                'error': {'code': 'model_not_available'},
              },
            }),
            status,
            headers: {'content-type': 'application/json'},
          ),
        );
        await expectLater(
          ChatSession(client, config(protocol), '', [
            {'role': 'user', 'content': '问'},
          ], '').events.toList(),
          throwsA(
            isA<ChatFailure>()
                .having((e) => e.code, 'code', 'model_not_available')
                .having((e) => e.message, 'message', contains('模型未开放或已下架')),
          ),
        );
      }
    });
  }
  test(
    'account enforces 128 messages including system using complete turns',
    () async {
      Map? body;
      final client = MockClient((r) async {
        body = jsonDecode(r.body) as Map;
        return http.Response(
          '{}',
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final history = <Map<String, String>>[
        for (var i = 0; i < 100; i++) ...[
          {'role': 'user', 'content': 'q$i'},
          {'role': 'assistant', 'content': 'a$i'},
        ],
        {'role': 'user', 'content': 'latest'},
      ];
      await ChatSession.account(
        client,
        config(ApiProtocol.chat),
        history,
        'system',
        'fake',
      ).events.toList();
      final messages = body!['messages'] as List;
      expect(messages.length, lessThanOrEqualTo(128));
      expect(messages[1]['role'], 'user');
      expect(messages.last['content'], 'latest');
      expect(history.length, 201);
    },
  );
  test(
    'overlong system cannot be silently discarded and makes no HTTP call',
    () async {
      var calls = 0;
      final client = MockClient((r) async {
        calls++;
        return http.Response('{}', 200);
      });
      await expectLater(
        ChatSession(client, config(ApiProtocol.chat, limit: 100), '', [
          {'role': 'user', 'content': '当前'},
        ], '设定' * 200).events.toList(),
        throwsA(
          isA<ChatFailure>().having(
            (e) => e.code,
            'code',
            'context_budget_exceeded',
          ),
        ),
      );
      expect(calls, 0);
    },
  );
  test('streaming response.failed retains unavailable code', () async {
    final client = MockClient(
      (r) async => http.Response(
        'data: ${jsonEncode({
          'type': 'response.failed',
          'response': {
            'error': {'code': 'model_not_available'},
          },
        })}\n\n',
        200,
        headers: {'content-type': 'text/event-stream'},
      ),
    );
    final c = ModelConnection.fromJson({
      ...config(ApiProtocol.responses).toJson(),
      'streaming': true,
    });
    await expectLater(
      ChatSession(client, c, '', [
        {'role': 'user', 'content': '问'},
      ], '').events.toList(),
      throwsA(
        isA<ChatFailure>().having((e) => e.code, 'code', 'model_not_available'),
      ),
    );
  });
  test(
    'account final serialized limit removes old image but keeps current media',
    () async {
      final image =
          'data:image/png;base64,${base64Encode(List.filled(140 * 1024, 0))}';
      final history = [
        {'role': 'user', 'content': '旧图', 'image': image},
        {'role': 'assistant', 'content': '旧回答'},
        {'role': 'user', 'content': '当前图', 'image': image},
      ];
      String? sent;
      final client = MockClient((r) async {
        sent = r.body;
        return http.Response(
          '{}',
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final events = await ChatSession.account(
        client,
        config(ApiProtocol.chat),
        history,
        'system',
        'fake',
      ).events.toList();
      expect(utf8.encode(sent!).length, lessThanOrEqualTo(262144));
      expect(events.first.notice, contains('历史图片'));
      expect(sent, contains('历史图片未重发'));
      expect(history.first['image'], image);
    },
  );
  test('current queued media overflow fails before HTTP', () async {
    var calls = 0;
    final image =
        'data:image/png;base64,${base64Encode(List.filled(140 * 1024, 0))}';
    final client = MockClient((r) async {
      calls++;
      return http.Response('{}', 200);
    });
    await expectLater(
      ChatSession.account(
        client,
        config(ApiProtocol.responses),
        [
          {'role': 'user', 'content': '图1', 'image': image},
          {'role': 'user', 'content': '图2', 'image': image},
        ],
        '',
        'fake',
      ).events.toList(),
      throwsA(
        isA<ChatFailure>().having(
          (e) => e.code,
          'code',
          'context_budget_exceeded',
        ),
      ),
    );
    expect(calls, 0);
  });
  test(
    'public plaintext blocks before key or history leaves process',
    () async {
      var calls = 0;
      final api = ChatApi(
        clientFactory: () => MockClient((r) async {
          calls++;
          return http.Response('{}', 200);
        }),
      );
      await expectLater(
        api
            .start(
              config(ApiProtocol.chat, address: 'http://example.test/v1'),
              'secret',
              [
                {'role': 'user', 'content': 'private'},
              ],
              '',
            )
            .events
            .toList(),
        throwsA(isA<ChatFailure>()),
      );
      expect(calls, 0);
      for (final host in [
        '127.0.0.1',
        '192.168.1.2',
        '10.0.2.2',
        '172.16.2.1',
        '[::1]',
      ]) {
        expect(
          config(
            ApiProtocol.chat,
            address: 'http://$host/v1',
          ).endpoint().scheme,
          'http',
        );
      }
      for (final host in [
        '172.32.1.1',
        '192.168.1.2.evil.test',
        '2130706433',
      ]) {
        expect(
          () => config(ApiProtocol.chat, address: 'http://$host/v1').endpoint(),
          throwsFormatException,
        );
      }
    },
  );
  test('Beta signs the final pruned body', () async {
    String? signed, sent;
    final client = MockClient((r) async {
      sent = r.body;
      return http.Response(
        '{}',
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    await ChatSession.beta(
      client,
      config(ApiProtocol.chat),
      [
        for (var i = 0; i < 100; i++) ...[
          {'role': 'user', 'content': 'q$i'},
          {'role': 'assistant', 'content': 'a$i'},
        ],
        {'role': 'user', 'content': 'latest'},
      ],
      'system',
      (body) async {
        signed = body;
        return {'X-Test': 'fake'};
      },
    ).events.toList();
    expect(signed, sent);
    final messages = (jsonDecode(sent!) as Map)['messages'] as List;
    expect(messages.length, lessThanOrEqualTo(128));
    expect(messages.first['content'], 'system');
    expect(messages.last['content'], 'latest');
  });
}

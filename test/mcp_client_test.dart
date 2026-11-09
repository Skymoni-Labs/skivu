import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ski/mcp_client.dart';

http.Response reply(
  dynamic id,
  dynamic result, {
  Map<String, String> headers = const {},
}) => http.Response(
  jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result}),
  200,
  headers: {'content-type': 'application/json', ...headers},
);
final tool = {
  'name': 'echo',
  'description': 'Echo text',
  'inputSchema': {
    'type': 'object',
    'properties': {
      'text': {'type': 'string'},
    },
  },
};

void main() {
  test(
    'keeps large requests, complete responses and paginated catalogs',
    () async {
      final input = '题目🙂' * 150000;
      final output = '完整结果🙂' * 500000;
      final description = '详细工具说明' * 5000;
      final cursor = 'page-' + 'x' * 5000;
      final client = McpClient(
        const McpConnection('http://localhost:8080/mcp'),
        client: MockClient((request) async {
          final body = jsonDecode(request.body);
          final id = body['id'];
          switch (body['method']) {
            case 'initialize':
              return reply(id, {
                'protocolVersion': '2025-11-25',
                'capabilities': {'tools': {}},
              });
            case 'notifications/initialized':
              return http.Response('', 202);
            case 'tools/list':
              final second = body['params']['cursor'] != null;
              if (second) expect(body['params']['cursor'], cursor);
              return reply(id, {
                'tools': [
                  for (var i = 0; i < 600; i++)
                    {
                      ...tool,
                      'name': 'tool_${i + (second ? 600 : 0)}',
                      'description': i == 0 ? description : '',
                    },
                ],
                if (!second) 'nextCursor': cursor,
              });
            default:
              expect(body['params']['arguments']['text'], input);
              return reply(id, {
                'content': [
                  {'type': 'text', 'text': output},
                ],
              });
          }
        }),
      );
      addTearDown(client.close);
      await client.initialize();
      final all = await client.listTools();
      expect(all, hasLength(1200));
      expect(all.first.description, description);
      expect(
        (await client.callTool(all.first, {
          'text': input,
        }))['content'][0]['text'],
        output,
      );
    },
  );

  test(
    'only explicitly configured deadline ends a pending MCP request',
    () async {
      final client = McpClient(
        const McpConnection('http://localhost/mcp', timeoutSeconds: 1),
        client: MockClient(
          (_) => Future<http.Response>.delayed(
            const Duration(seconds: 2),
            () => http.Response('', 503),
          ),
        ),
      );
      addTearDown(client.close);
      await expectLater(
        client.initialize(),
        throwsA(
          isA<McpFailure>().having(
            (e) => e.message,
            'message',
            contains('你设置的超时'),
          ),
        ),
      );
      await expectLater(
        client.initialize(),
        throwsA(
          isA<McpFailure>().having(
            (e) => e.message,
            'message',
            contains('已关闭'),
          ),
        ),
      );
    },
  );
  test(
    'negotiates session and protocol, paginates, calls only when requested',
    () async {
      final methods = <String>[];
      final client = McpClient(
        const McpConnection(
          'https://example.com/mcp',
          token: 'private-test-token',
        ),
        client: MockClient((request) async {
          expect(request.followRedirects, isFalse);
          expect(request.headers['Authorization'], 'Bearer private-test-token');
          final data = jsonDecode(request.body);
          methods.add(data['method']);
          if (data['method'] == 'initialize')
            return reply(
              data['id'],
              {
                'protocolVersion': '2025-11-25',
                'capabilities': {'tools': {}},
              },
              headers: {'mcp-session-id': 'session-1'},
            );
          expect(request.headers['Mcp-Session-Id'], 'session-1');
          expect(request.headers['MCP-Protocol-Version'], '2025-11-25');
          if (data['method'] == 'notifications/initialized')
            return http.Response('', 202);
          if (data['method'] == 'tools/list')
            return reply(
              data['id'],
              data['params']['cursor'] == null
                  ? {
                      'tools': [tool],
                      'nextCursor': 'page-2',
                    }
                  : {'tools': []},
            );
          expect(data['method'], 'tools/call');
          expect(data['params'], {
            'name': 'echo',
            'arguments': {'text': 'hello'},
          });
          return reply(data['id'], {
            'content': [
              {'type': 'text', 'text': 'hello'},
            ],
          });
        }),
      );
      addTearDown(client.close);
      await client.initialize();
      final tools = await client.listTools();
      expect(methods, [
        'initialize',
        'notifications/initialized',
        'tools/list',
        'tools/list',
      ]);
      final result = await client.callTool(tools.single, {'text': 'hello'});
      expect(result['content'][0]['text'], 'hello');
    },
  );

  test(
    'reads SSE results with informational notifications before matching response',
    () async {
      final client = McpClient(
        const McpConnection('https://example.com/mcp'),
        client: MockClient((request) async {
          final data = jsonDecode(request.body), id = data['id'];
          if (data['method'] == 'notifications/initialized')
            return http.Response('', 202);
          final result = data['method'] == 'initialize'
              ? {
                  'protocolVersion': '2025-06-18',
                  'capabilities': {'tools': {}},
                }
              : {
                  'tools': [tool],
                };
          return http.Response(
            'id: heartbeat\ndata: \n\nevent: message\ndata: {"jsonrpc":"2.0","method":"notifications/progress","params":{}}\n\nevent: message\ndata: ${jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result})}\n\n',
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }),
      );
      addTearDown(client.close);
      await client.initialize();
      expect((await client.listTools()).single.name, 'echo');
    },
  );

  for (final status in [302, 401, 404, 500]) {
    test(
      'refuses HTTP $status without following redirects or echoing remote error',
      () async {
        var calls = 0;
        final client = McpClient(
          const McpConnection('https://example.com/mcp', token: 'do-not-leak'),
          client: MockClient((request) async {
            calls++;
            return http.Response(
              'do-not-leak',
              status,
              headers: {'location': 'https://other.example/mcp'},
            );
          }),
        );
        addTearDown(client.close);
        try {
          await client.initialize();
          fail('must reject');
        } on McpFailure catch (error) {
          expect(error.message, isNot(contains('do-not-leak')));
        }
        expect(calls, 1);
      },
    );
  }

  test('rejects unsupported protocol and response ID mismatch', () async {
    for (final invalidId in [false, true]) {
      final client = McpClient(
        const McpConnection('https://example.com/mcp'),
        client: MockClient((request) async {
          final data = jsonDecode(request.body);
          return reply(invalidId ? 999 : data['id'], {
            'protocolVersion': '2099-01-01',
            'capabilities': {'tools': {}},
          });
        }),
      );
      await expectLater(client.initialize(), throwsA(isA<McpFailure>()));
      client.close();
    }
  });

  test(
    'accepts configured HTTP and rejects header injection and use before initialize',
    () async {
      final local = McpClient(const McpConnection('http://localhost:8080/mcp'));
      expect(local.endpoint.scheme, 'http');
      local.close();
      expect(
        () => McpClient(
          const McpConnection(
            'https://example.com/mcp',
            token: 'x\r\nAuthorization: bad',
          ),
        ),
        throwsA(isA<McpFailure>()),
      );
      final client = McpClient(const McpConnection('https://example.com/mcp'));
      addTearDown(client.close);
      await expectLater(client.listTools(), throwsA(isA<McpFailure>()));
    },
  );
}

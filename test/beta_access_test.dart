import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ski/beta_access.dart';
import 'package:ski/chat_api.dart';
import 'package:ski/model_settings.dart';
import 'package:ski/state.dart';
import 'chat_api_test.dart' show connection;
import 'package:ski/model_connection.dart';
import 'real_chat_store_test.dart' show MemoryChats;

class FakeKeystore extends BetaKeystore {
  int attestations = 0;
  final signed = <Map<String, dynamic>>[];
  @override
  bool get supported => true;
  @override
  Future<bool> exists(String alias) async => true;
  @override
  Future<void> delete(String alias) async {}
  @override
  Future<Map<String, dynamic>> attest(String challenge) async {
    expect(base64Url.decode(base64Url.normalize(challenge)).length, 32);
    attestations++;
    return {
      'alias': 'skivu_beta_00000000-0000-0000-0000-000000000000',
      'chain': ['leaf-test', 'root-test'],
      'label': 'Test Android',
    };
  }

  @override
  Future<String> sign(Map<String, dynamic> fields) async {
    signed.add(Map.of(fields));
    return 'test-der-proof';
  }
}

http.Response betaResponse(Map<String, dynamic> data) => http.Response(
  jsonEncode({'success': true, 'data': data}),
  200,
  headers: {'content-type': 'application/json'},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test(
    'enroll, proof signing and wallet state follow the fixed beta contract',
    () async {
      final key = FakeKeystore();
      final requests = <http.Request>[];
      final beta = BetaAccess(
        keystore: key,
        clientFactory: () => MockClient((r) async {
          requests.add(r);
          expect(r.url.scheme, 'https');
          expect(r.url.host, 'skymoni.com');
          expect(r.followRedirects, isFalse);
          if (r.url.path.endsWith('/challenge'))
            return betaResponse({
              'id': 'challenge-id',
              'challenge': base64UrlEncode(
                List.filled(32, 7),
              ).replaceAll('=', ''),
            });
          if (r.url.path.endsWith('/enroll')) {
            final body = jsonDecode(r.body) as Map;
            expect(body['challenge_id'], 'challenge-id');
            expect(body['chain'], ['leaf-test', 'root-test']);
            return betaResponse({
              'device_token': 'beta-device-token-test-only',
              'pair_code': 'AABBCCDDEEFF0011',
              'pair_expires':
                  DateTime.now().millisecondsSinceEpoch ~/ 1000 + 300,
            });
          }
          return betaResponse({
            'paired': true,
            'account': {
              'status': 'approved',
              'balance': 1000,
              'reserved': 100,
              'used': 25,
            },
            'models': ['beta-model', 'beta-responses', 'unsupported-model'],
            'model_protocols': {
              'beta-model': 'chat',
              'beta-responses': 'responses',
              'unsupported-model': 'future-protocol',
            },
            'quota_per_unit': 500000,
          });
        }),
      );
      await beta.enroll();
      expect(beta.error, isNull);
      expect(beta.pairCode, 'AABBCCDDEEFF0011');
      expect(beta.enrolled, isTrue);
      await beta.refresh();
      expect(beta.canChat, isTrue);
      expect(beta.activeModel, 'beta-model');
      expect(beta.models, ['beta-model', 'beta-responses']);
      expect(beta.account!['balance'], 1000);
      final fields = key.signed.single;
      expect(fields['method'], 'GET');
      expect(fields['path'], '/api/app-beta/device');
      expect(fields['bodyHash'], sha256.convert(utf8.encode('')).toString());
      expect(
        fields['tokenHash'],
        sha256.convert(utf8.encode('beta-device-token-test-only')).toString(),
      );
      expect(
        base64Url.decode(base64Url.normalize(fields['nonce'] as String)).length,
        24,
      );
      expect(
        requests.last.headers['Authorization'],
        'BetaDevice beta-device-token-test-only',
      );
      expect(requests.last.headers['X-Beta-Proof'], 'test-der-proof');
      final headers = await beta.signedHeaders(
        'POST',
        '/api/app-beta/chat/completions',
        '{"内容":"你好"}',
      );
      expect(
        key.signed.last['bodyHash'],
        sha256.convert(utf8.encode('{"内容":"你好"}')).toString(),
      );
      expect(
        headers['X-Beta-Nonce'],
        isNot(requests.last.headers['X-Beta-Nonce']),
      );
      await beta.selectModel('beta-responses');
      expect(beta.connection!.protocol, ApiProtocol.responses);
      expect(
        beta.connection!.address,
        'https://skymoni.com/api/app-beta/responses',
      );
      await beta.signedHeaders('POST', '/api/app-beta/responses', '{}');
      expect(key.signed.last['path'], '/api/app-beta/responses');
      await expectLater(
        beta.signedHeaders('POST', '/v1/chat/completions', ''),
        throwsA(isA<ChatFailure>()),
      );
      beta.dispose();
    },
  );

  test(
    'disabled service never generates hardware keys or silently enables beta',
    () async {
      final key = FakeKeystore();
      final beta = BetaAccess(
        keystore: key,
        clientFactory: () => MockClient((r) async => http.Response('', 503)),
      );
      await beta.enroll();
      expect(key.attestations, 0);
      expect(beta.enrolled, isFalse);
      expect(beta.canChat, isFalse);
      expect(beta.error, contains('尚未开放'));
      beta.dispose();
    },
  );

  test(
    'beta chat cannot send credentials to a custom host and uses only allowed body fields',
    () async {
      final config = connection(
        ApiProtocol.chat,
        address: 'https://custom.example/v1',
      );
      final client = MockClient((r) async {
        expect(
          r.url.toString(),
          'https://skymoni.com/api/app-beta/chat/completions',
        );
        expect(r.headers['Authorization'], 'BetaDevice test-token');
        expect(r.followRedirects, isFalse);
        final body = jsonDecode(r.body) as Map;
        expect(body.keys.toSet(), {
          'model',
          'messages',
          'stream',
          'max_tokens',
        });
        expect((body['messages'] as List).first['role'], 'system');
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': 'beta fixture reply'},
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final session = ChatSession.beta(
        client,
        config,
        [
          {'role': 'user', 'content': '你好'},
        ],
        '角色',
        (body) async => {
          'Authorization': 'BetaDevice test-token',
          'X-Beta-Proof': 'proof',
        },
      );
      expect((await session.events.toList()).single.text, 'beta fixture reply');
    },
  );

  test(
    'beta responses keeps the native protocol and strict signed body',
    () async {
      String? signedBody;
      final session = ChatSession.beta(
        MockClient((r) async {
          expect(
            r.url.toString(),
            'https://skymoni.com/api/app-beta/responses',
          );
          expect(r.body, signedBody);
          final body = jsonDecode(r.body) as Map;
          expect(body.keys.toSet(), {
            'model',
            'input',
            'instructions',
            'stream',
            'max_output_tokens',
            'store',
          });
          expect(body['input'], [
            {'role': 'user', 'content': '你好'},
          ]);
          expect(body['instructions'], '角色');
          expect(body['store'], isFalse);
          return http.Response.bytes(
            utf8.encode(
              'data: {"type":"response.output_text.delta","delta":"你好"}\n\n'
              'data: {"type":"response.completed","response":{"usage":{"input_tokens":3,"output_tokens":2}}}\n\n',
            ),
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }),
        connection(ApiProtocol.responses, address: 'https://custom.example'),
        [
          {'role': 'user', 'content': '你好'},
        ],
        '角色',
        (body) async {
          signedBody = body;
          return {'Authorization': 'BetaDevice fixture-token'};
        },
      );
      final events = await session.events.toList();
      expect(events.map((e) => e.text).join(), '你好');
      expect(events.last.usage!.output, 2);
      expect(events.last.done, isTrue);
    },
  );

  test(
    'unpaired beta selection never falls back to an ordinary API key',
    () async {
      var normalCalls = 0;
      final models = ModelSettings()
        ..connections.add(connection(ApiProtocol.chat))
        ..activeId = 'test';
      final beta = BetaAccess(keystore: FakeKeystore());
      final store = DemoStore(
        settings: models,
        beta: beta,
        storage: MemoryChats(),
        api: ChatApi(
          clientFactory: () {
            normalCalls++;
            return MockClient((r) async => http.Response('{}', 200));
          },
        ),
      )..useBeta = true;
      expect(store.send('测试'), isFalse);
      expect(normalCalls, 0);
      expect(store.messages, isEmpty);
      expect(store.lastError, contains('内测配对'));
      store.dispose();
      models.dispose();
      beta.dispose();
    },
  );
}

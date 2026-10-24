import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ski/app_platform.dart';
import 'package:ski/chat_api.dart';
import 'package:ski/model_connection.dart';
import 'package:ski/model_settings.dart';
import 'package:ski/relay_account.dart';
import 'package:ski/state.dart';
import 'real_chat_store_test.dart' show MemoryChats, waitForReply;
import 'chat_api_test.dart' show connection;

class AccountPlatform extends AppPlatform {
  final opened = <String>[];
  @override
  bool get supported => true;
  @override
  Future<void> openWebsite(String url) async {
    opened.add(url);
  }
}

http.Response ok(Map data) => http.Response.bytes(
  utf8.encode(jsonEncode({'success': true, 'data': data})),
  200,
);
http.Response failure(String code, int status) =>
    http.Response(jsonEncode({'success': false, 'code': code}), status);
Map<String, dynamic> authorization({
  String url = 'https://skymoni.com/app-authorize?user_code=ABCD-1234',
}) => {
  'device_code': 'fixture-device-code',
  'user_code': 'ABCD-1234',
  'verification_uri_complete': url,
  'expires_in': 600,
  'interval': 5,
};
Map<String, dynamic> token() => {
  'access_token': 'fixture-account-access-token',
  'token_type': 'AppAccount',
  'expires_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
  'session_id': 9,
};
Map<String, dynamic> me() => {
  'user': {
    'id': 7,
    'username': 'fixture',
    'display_name': 'Fixture user',
    'group': 'default',
  },
  'wallet': {'balance': 123456789, 'used': 10000, 'request_count': 2},
  'quota_per_unit': 100000000,
  'currency': 'USD',
  'billing_preference': 'subscription_first',
  'subscriptions': [
    {
      'id': 1,
      'plan_id': 3,
      'total': 0,
      'used': 50,
      'unlimited': true,
      'remaining': null,
    },
  ],
  'session': {
    'id': 9,
    'expires_at': token()['expires_at'],
    'device_name': 'Skivu Android',
  },
};
Map<String, dynamic> catalog() => {
  'models': ['chat-fixture', 'responses-fixture', 'unsupported'],
  'model_protocols': {
    'chat-fixture': 'chat',
    'responses-fixture': 'responses',
    'unsupported': 'future',
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test(
    'account Responses never forwards a session to custom hosts and preserves strict protocol',
    () async {
      final session = ChatSession.account(
        MockClient((request) async {
          expect(
            request.url.toString(),
            'https://skymoni.com/api/app-account/responses',
          );
          expect(
            request.headers['Authorization'],
            'AppAccount fixture-session',
          );
          expect(request.followRedirects, isFalse);
          final body = jsonDecode(request.body) as Map;
          expect(body.keys.toSet(), {
            'model',
            'input',
            'instructions',
            'stream',
            'max_output_tokens',
            'store',
          });
          expect(body['store'], isFalse);
          expect(body['instructions'], 'role');
          return http.Response(
            jsonEncode({
              'output': [
                {
                  'content': [
                    {'type': 'output_text', 'text': 'fixture response'},
                  ],
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
        connection(ApiProtocol.responses, address: 'https://untrusted.example'),
        [
          {'role': 'user', 'content': 'hello'},
        ],
        'role',
        'fixture-session',
      );
      expect((await session.events.toList()).single.text, 'fixture response');
    },
  );

  test(
    'account quota/permission errors do not ask users to enter an API Key',
    () async {
      final session = ChatSession.account(
        MockClient((request) async => http.Response('{}', 403)),
        connection(ApiProtocol.chat),
        [
          {'role': 'user', 'content': 'hello'},
        ],
        '',
        'fixture-session',
      );
      await expectLater(
        session.events.drain<void>(),
        throwsA(
          isA<ChatFailure>()
              .having((e) => e.message, 'message', contains('额度'))
              .having((e) => e.message, 'message', isNot(contains('API Key'))),
        ),
      );
    },
  );

  test(
    'browser login binds PKCE, stores only a restricted session and syncs wallet/catalog',
    () async {
      final platform = AccountPlatform();
      final requests = <http.Request>[];
      String? challenge;
      final clients = () => MockClient((r) async {
        requests.add(r);
        expect(r.url.host, 'skymoni.com');
        expect(r.url.scheme, 'https');
        expect(r.followRedirects, isFalse);
        switch (r.url.path.split('/').last) {
          case 'authorize':
            final body = jsonDecode(r.body) as Map;
            expect(body.keys.toSet(), {'code_challenge', 'device_name'});
            challenge = body['code_challenge'];
            return ok(authorization());
          case 'token':
            final body = jsonDecode(r.body) as Map;
            expect(body.keys.toSet(), {'device_code', 'code_verifier'});
            final verifier = body['code_verifier'] as String;
            expect(verifier.length, inInclusiveRange(43, 128));
            expect(
              base64UrlEncode(
                sha256.convert(ascii.encode(verifier)).bytes,
              ).replaceAll('=', ''),
              challenge,
            );
            return ok(token());
          case 'me':
            expect(
              r.headers['Authorization'],
              'AppAccount fixture-account-access-token',
            );
            return ok(me());
          case 'models':
            return ok(catalog());
          default:
            throw StateError('Unexpected request');
        }
      });
      final account = RelayAccount(platform: platform, clientFactory: clients);
      await account.beginAuthorization();
      expect(account.authorizing, isTrue);
      expect(account.userCode, 'ABCD-1234');
      expect(platform.opened.single, startsWith('https://skymoni.com/'));
      await account.pollAuthorization();
      expect(account.error, isNull);
      expect(account.canChat, isTrue);
      expect(account.models, ['chat-fixture', 'responses-fixture']);
      expect(account.quotaPerUnit, 100000000);
      expect(account.wallet!['balance'], 123456789);
      expect(account.subscriptions.single['remaining'], isNull);
      await account.selectModel('responses-fixture');
      expect(account.connection!.protocol, ApiProtocol.responses);
      final restored = RelayAccount(platform: platform, clientFactory: clients);
      await restored.restore();
      expect(restored.canChat, isFalse);
      await restored.refresh();
      expect(restored.canChat, isTrue);
      expect(restored.activeModel, 'responses-fixture');
      expect(requests.any((r) => r.body.contains('password')), isFalse);
      account.dispose();
      restored.dispose();
    },
  );

  test(
    'pending auth respects slowdown and session limit stops automatic polling',
    () async {
      var polls = 0;
      final account = RelayAccount(
        platform: AccountPlatform(),
        clientFactory: () => MockClient((r) async {
          if (r.url.path.endsWith('/authorize')) return ok(authorization());
          polls++;
          return switch (polls) {
            1 => failure('AUTHORIZATION_PENDING', 403),
            2 => failure('SLOW_DOWN', 429),
            _ => failure('AUTH_SESSION_LIMIT', 429),
          };
        }),
      );
      await account.beginAuthorization();
      await account.pollAuthorization();
      expect(account.error, isNull);
      await account.pollAuthorization();
      expect(account.pollInterval, 10);
      await account.pollAuthorization();
      expect(account.authorizing, isFalse);
      expect(account.error, contains('上限'));
      await account.pollAuthorization();
      expect(polls, 3);
      account.dispose();
    },
  );

  test(
    'cancelled token exchange revokes only the newly issued session',
    () async {
      final pending = Completer<http.Response>();
      var revoked = 0;
      final account = RelayAccount(
        platform: AccountPlatform(),
        clientFactory: () => MockClient((r) async {
          if (r.url.path.endsWith('/authorize')) return ok(authorization());
          if (r.url.path.endsWith('/token')) return pending.future;
          expect(r.method, 'DELETE');
          expect(r.url.path, '/api/app-account/session');
          expect(
            r.headers['Authorization'],
            'AppAccount fixture-account-access-token',
          );
          revoked++;
          return ok({});
        }),
      );
      await account.beginAuthorization();
      final exchange = account.pollAuthorization();
      await Future<void>.delayed(Duration.zero);
      await account.cancelAuthorization();
      pending.complete(ok(token()));
      await exchange;
      expect(account.signedIn, isFalse);
      expect(revoked, 1);
      account.dispose();
    },
  );

  test(
    'external authorization links never open and no native session is saved',
    () async {
      final platform = AccountPlatform();
      final account = RelayAccount(
        platform: platform,
        clientFactory: () => MockClient(
          (r) async =>
              ok(authorization(url: 'https://untrusted.example/authorize')),
        ),
      );
      await account.beginAuthorization();
      expect(platform.opened, isEmpty);
      expect(account.authorizing, isFalse);
      expect(account.error, contains('地址'));
      expect(account.signedIn, isFalse);
      account.dispose();
    },
  );

  test(
    'expired or revoked sessions are removed on refresh without a custom API fallback',
    () async {
      var invalid = false, normalCalls = 0;
      final account = RelayAccount(
        platform: AccountPlatform(),
        clientFactory: () => MockClient((r) async {
          if (r.url.path.endsWith('/authorize')) return ok(authorization());
          if (r.url.path.endsWith('/token')) return ok(token());
          if (invalid) return failure('APP_SESSION_INVALID', 401);
          return ok(r.url.path.endsWith('/me') ? me() : catalog());
        }),
      );
      await account.beginAuthorization();
      await account.pollAuthorization();
      final models = ModelSettings();
      final store = DemoStore(
        account: account,
        settings: models,
        storage: MemoryChats(),
        api: ChatApi(
          clientFactory: () {
            normalCalls++;
            throw StateError('Not permitted');
          },
        ),
      )..useAccount = true;
      invalid = true;
      await account.refresh();
      expect(account.signedIn, isFalse);
      expect(account.error, contains('过期'));
      expect(store.send('hello'), isFalse);
      expect(normalCalls, 0);
      expect(store.messages, isEmpty);
      store.dispose();
      models.dispose();
      account.dispose();
    },
  );

  test(
    'account chat uses strict fixed-host bodies and chat invalidation clears native session',
    () async {
      var expire = false;
      final account = RelayAccount(
        platform: AccountPlatform(),
        clientFactory: () => MockClient((r) async {
          if (r.url.path.endsWith('/authorize')) return ok(authorization());
          if (r.url.path.endsWith('/token')) return ok(token());
          if (r.url.path.endsWith('/me')) return ok(me());
          if (r.url.path.endsWith('/models')) return ok(catalog());
          expect(
            r.url.toString(),
            'https://skymoni.com/api/app-account/chat/completions',
          );
          expect(
            r.headers['Authorization'],
            'AppAccount fixture-account-access-token',
          );
          expect((jsonDecode(r.body) as Map).keys.toSet(), {
            'model',
            'messages',
            'stream',
            'max_tokens',
          });
          if (expire) return failure('APP_SESSION_INVALID', 401);
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': 'account reply'},
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      await account.beginAuthorization();
      await account.pollAuthorization();
      final models = ModelSettings();
      final chats = MemoryChats();
      final store = DemoStore(
        account: account,
        settings: models,
        storage: chats,
      )..useAccount = true;
      await store.restore();
      store.useAccount = true;
      expect(store.send('hello'), isTrue);
      await waitForReply(store);
      expect(store.messages.last.text, 'account reply');
      expect(models.connections, isEmpty);
      await store.saveChats();
      expect(chats.data, isNot(contains('fixture-account-access-token')));
      // Complete the post-generation quota refresh before the next request.
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expire = true;
      expect(store.send('again'), isTrue);
      await waitForReply(store);
      expect(store.messages.last.status, 'failed');
      expect(account.signedIn, isFalse);
      store.dispose();
      models.dispose();
      account.dispose();
    },
  );
}

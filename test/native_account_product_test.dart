import 'dart:async';
import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ski/relay_account.dart';
import 'package:ski/chat_api.dart';
import 'real_chat_store_test.dart' show MemoryChats, TestModels, waitForReply;
import 'package:ski/state.dart';
import 'relay_account_test.dart' show AccountPlatform, ok, token, me, catalog;

class EncryptedPlatform extends AccountPlatform {
  String? encryptedInput;
  @override
  Future<String> encryptPassword(String password, String publicKey) async {
    encryptedInput = password;
    return 'fixture-sealed-password';
  }
}

Map options({bool captcha = false}) => {
  'password_login_enabled': true,
  'encryption': {
    'enabled': true,
    'kid': 'fixture-key',
    'public_key': 'fixture-public-key',
  },
  'captcha': {'required': captcha},
};
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  test(
    'logout clears local credentials offline and another account gets a fresh catalog',
    () async {
      var username = '', deleted = '';
      final account = RelayAccount(
        platform: AccountPlatform(),
        clientFactory: () => MockClient((r) async {
          if (r.method == 'DELETE') {
            deleted = r.headers['Authorization']!;
            throw http.ClientException('fixture offline');
          }
          switch (r.url.path.split('/').last) {
            case 'options':
              return ok({
                'password_login_enabled': true,
                'encryption': {'enabled': false},
                'captcha': {'required': false},
              });
            case 'login':
              username = (jsonDecode(r.body) as Map)['username'] as String;
              return ok({
                ...token(),
                'access_token': 'fixture-$username-token',
              });
            case 'me':
              return ok({
                ...me(),
                'user': {'username': username},
              });
            case 'models':
              return ok({
                'models': ['$username-model'],
                'model_protocols': {'$username-model': 'chat'},
              });
            default:
              return ok({});
          }
        }),
      );
      await account.signIn('first', 'fixture-password');
      expect(account.activeModel, 'first-model');
      await account.logout();
      expect(account.signedIn, isFalse);
      expect(account.models, isEmpty);
      expect(account.activeModel, isNull);
      expect(account.funding, 'relay');
      expect(deleted, 'AppAccount fixture-first-token');
      expect(await const FlutterSecureStorage().readAll(), isEmpty);
      expect(account.error, contains('已退出本机'));
      await account.signIn('second', 'fixture-password');
      expect(account.signedIn, isTrue);
      expect(account.user?['username'], 'second');
      expect(account.models, ['second-model']);
      expect(account.error, isNull);
      account.dispose();
    },
  );
  test(
    'logout during refresh prevents a late response from restoring the old account',
    () async {
      final pending = Completer<http.Response>();
      var refreshing = false;
      final account = RelayAccount(
        platform: AccountPlatform(),
        clientFactory: () => MockClient((r) async {
          switch (r.url.path.split('/').last) {
            case 'options':
              return ok({
                'password_login_enabled': true,
                'encryption': {'enabled': false},
                'captcha': {'required': false},
              });
            case 'login':
              return ok(token());
            case 'me':
              return refreshing ? pending.future : ok(me());
            case 'models':
              return ok(catalog());
            default:
              return ok({});
          }
        }),
      );
      await account.signIn('fixture', 'fixture-password');
      refreshing = true;
      final refresh = account.refresh();
      await Future<void>.delayed(Duration.zero);
      expect(account.busy, isTrue);
      await account.logout();
      pending.complete(ok(me()));
      await refresh;
      expect(account.signedIn, isFalse);
      expect(account.user, isNull);
      expect(account.models, isEmpty);
      expect(account.busy, isFalse);
      expect(await const FlutterSecureStorage().readAll(), isEmpty);
      account.dispose();
    },
  );
  test(
    'native login encrypts password and persists only scoped session; beta funding is explicit',
    () async {
      final platform = EncryptedPlatform();
      final bodies = <Map>[];
      final account = RelayAccount(
        platform: platform,
        clientFactory: () => MockClient((r) async {
          switch (r.url.path.split('/').last) {
            case 'options':
              return ok(Map<String, dynamic>.from(options()));
            case 'login':
              final body = jsonDecode(r.body) as Map;
              expect(body.containsKey('password'), isFalse);
              expect(body['password_encrypted'], 'fixture-sealed-password');
              return ok(token());
            case 'me':
              return ok({
                ...me(),
                'beta': {
                  'account_approved': true,
                  'can_chat': true,
                  'account': {
                    'status': 'approved',
                    'balance': 100000000,
                    'reserved': 200,
                    'used': 100,
                  },
                },
              });
            case 'models':
              return ok(catalog());
            case 'completions':
              bodies.add(jsonDecode(r.body) as Map);
              return http.Response(
                jsonEncode({
                  'choices': [
                    {
                      'message': {'content': 'fixture reply'},
                    },
                  ],
                }),
                200,
              );
            default:
              return ok({});
          }
        }),
      );
      await account.signIn('fixture-user', 'fixture-password');
      expect(account.signedIn, isTrue);
      expect(account.canChat, isTrue);
      expect(platform.opened, isEmpty);
      expect(platform.encryptedInput, 'fixture-password');
      expect(account.betaAccount['balance'], 100000000);
      await account.selectFunding('beta');
      await account.setGeneration(512, false);
      await account
          .startChat([
            {'role': 'user', 'content': 'fixture input'},
          ], '')
          .events
          .toList();
      expect(bodies.single['funding'], 'beta');
      expect(bodies.single['max_tokens'], 512);
      await account.selectFunding('relay');
      await account
          .startChat([
            {'role': 'user', 'content': 'fixture input'},
          ], '')
          .events
          .toList();
      expect(bodies.last.containsKey('funding'), isFalse);
      final saved = await const FlutterSecureStorage().read(
        key: 'skivu.relay.account.v1',
      );
      expect(saved, isNot(contains('fixture-password')));
      expect(saved, isNot(contains('password_encrypted')));
      account.dispose();
    },
  );
  test(
    'MFA uses available method objects and verifier result without retaining password',
    () async {
      final a = RelayAccount(
        platform: EncryptedPlatform(),
        clientFactory: () => MockClient((r) async {
          if (r.url.path.endsWith('options'))
            return ok(Map<String, dynamic>.from(options()));
          if (r.url.path.endsWith('/login'))
            return ok({
              'require_verification': true,
              'flow_token': 'fixture-flow',
              'methods': [
                {'method': '2fa', 'available': true},
              ],
            });
          if (r.url.path.endsWith('/verify')) {
            expect(jsonDecode(r.body), {
              'flow_token': 'fixture-flow',
              'method': '2fa',
              'code': '123456',
            });
            return ok(token());
          }
          if (r.url.path.endsWith('/me')) return ok(me());
          if (r.url.path.endsWith('/models')) return ok(catalog());
          return ok({});
        }),
      );
      await a.signIn('fixture-user', 'fixture-password');
      expect(a.signedIn, isFalse);
      expect(a.needsBrowser, isFalse);
      await a.verifySignIn('123456');
      expect(a.signedIn, isTrue);
      expect(a.verificationFlow, isNull);
      a.dispose();
    },
  );
  test('unapproved or exhausted beta never falls back to wallet', () async {
    final a = RelayAccount(
      platform: EncryptedPlatform(),
      clientFactory: () => MockClient((r) async {
        if (r.url.path.endsWith('options'))
          return ok(Map<String, dynamic>.from(options()));
        if (r.url.path.endsWith('/login')) return ok(token());
        if (r.url.path.endsWith('/me'))
          return ok({
            ...me(),
            'beta': {
              'can_chat': false,
              'account_approved': true,
              'blocked_reason': 'QUOTA_EXHAUSTED',
              'account': {'status': 'approved', 'balance': 0},
            },
          });
        if (r.url.path.endsWith('/models')) return ok(catalog());
        throw StateError('Unexpected paid request');
      }),
    );
    await a.signIn('fixture-user', 'fixture-password');
    await a.selectFunding('beta');
    expect(a.connection, isNull);
    expect(a.canChat, isFalse);
    expect(a.betaMessage, contains('用完'));
    expect(() => a.startChat([], ''), throwsA(isA<Exception>()));
    expect(a.funding, 'beta');
    a.dispose();
  });
  test(
    'captcha and HTTP200 login failure never create a native session',
    () async {
      for (final captcha in [true, false]) {
        var posted = false;
        final a = RelayAccount(
          platform: EncryptedPlatform(),
          clientFactory: () => MockClient((r) async {
            if (r.url.path.endsWith('options'))
              return ok(Map<String, dynamic>.from(options(captcha: captcha)));
            posted = true;
            return http.Response(
              jsonEncode({'success': false, 'code': 'LOGIN_FAILED'}),
              200,
            );
          }),
        );
        await a.signIn('fixture-user', 'fixture-password');
        expect(a.signedIn, isFalse);
        expect(posted, !captcha);
        expect(a.needsBrowser, captcha);
        a.dispose();
      }
    },
  );
  test('cancelled native login revokes its late-issued session', () async {
    final login = Completer<http.Response>();
    var revoked = 0;
    final a = RelayAccount(
      platform: EncryptedPlatform(),
      clientFactory: () => MockClient((r) async {
        if (r.url.path.endsWith('options'))
          return ok(Map<String, dynamic>.from(options()));
        if (r.url.path.endsWith('/login')) return login.future;
        if (r.method == 'DELETE') {
          revoked++;
          return ok({});
        }
        return ok({});
      }),
    );
    final pending = a.signIn('fixture-user', 'fixture-password');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await a.cancelAuthorization();
    login.complete(ok(token()));
    await pending;
    expect(a.signedIn, isFalse);
    expect(revoked, 1);
    a.dispose();
  });
  test(
    'structured character fields round-trip without breaking old prompt',
    () {
      final original = demo.role;
      final p = Persona.fromJson(original.toJson());
      p.card = {
        '角色描述': 'fixture description',
        '性格与说话方式': 'fixture voice',
        '开场白': 'fixture greeting',
      };
      final restored = Persona.fromJson(p.toJson());
      expect(restored.compiledPrompt, contains('fixture description'));
      expect(restored.compiledPrompt, isNot(contains('fixture greeting')));
      expect(
        Persona.fromJson({...original.toJson(), 'card': null}).compiledPrompt,
        original.prompt,
      );
    },
  );
  test(
    'revoked beta status is refreshed even when its model catalogue is denied',
    () async {
      var approved = true;
      final a = RelayAccount(
        platform: EncryptedPlatform(),
        clientFactory: () => MockClient((r) async {
          if (r.url.path.endsWith('options'))
            return ok(Map<String, dynamic>.from(options()));
          if (r.url.path.endsWith('/login')) return ok(token());
          if (r.url.path.endsWith('/me'))
            return ok({
              ...me(),
              'beta': {
                'can_chat': approved,
                'account_approved': approved,
                'blocked_reason': approved ? '' : 'NOT_APPROVED',
                'account': {
                  'status': approved ? 'approved' : 'suspended',
                  'balance': 100,
                },
              },
            });
          if (r.url.path.endsWith('/models'))
            return !approved && r.url.queryParameters['funding'] == 'beta'
                ? http.Response(
                    jsonEncode({'success': false, 'code': 'BETA_NOT_APPROVED'}),
                    403,
                  )
                : ok(catalog());
          return ok({});
        }),
      );
      await a.signIn('fixture-user', 'fixture-password');
      expect(a.canBetaChat, isTrue);
      approved = false;
      await a.selectFunding('beta');
      expect(a.betaAccount['status'], 'suspended');
      expect(a.models, isEmpty);
      expect(a.protocols, isEmpty);
      expect(a.canChat, isFalse);
      expect(a.funding, 'beta');
      a.dispose();
    },
  );
  test(
    'beta quota errors retain the native login and report the actual funding source',
    () async {
      final a = RelayAccount(
        platform: EncryptedPlatform(),
        clientFactory: () => MockClient((r) async {
          if (r.url.path.endsWith('options'))
            return ok(Map<String, dynamic>.from(options()));
          if (r.url.path.endsWith('/login')) return ok(token());
          if (r.url.path.endsWith('/me'))
            return ok({
              ...me(),
              'beta': {
                'can_chat': true,
                'account_approved': true,
                'account': {'status': 'approved', 'balance': 100},
              },
            });
          if (r.url.path.endsWith('/models')) return ok(catalog());
          return http.Response(
            jsonEncode({'success': false, 'code': 'BETA_QUOTA_EXHAUSTED'}),
            403,
          );
        }),
      );
      await a.signIn('fixture-user', 'fixture-password');
      await a.selectFunding('beta');
      await expectLater(
        a
            .startChat([
              {'role': 'user', 'content': 'fixture'},
            ], '')
            .events
            .toList(),
        throwsA(
          isA<ChatFailure>().having(
            (e) => e.code,
            'code',
            'BETA_QUOTA_EXHAUSTED',
          ),
        ),
      );
      expect(a.signedIn, isTrue);
      expect(a.funding, 'beta');
      a.dispose();
    },
  );
  test(
    'character and user cards actually reach the request and survive backup restore',
    () async {
      Map? body;
      final store = DemoStore(
        settings: TestModels(),
        storage: MemoryChats(),
        api: ChatApi(
          clientFactory: () => MockClient((r) async {
            body = jsonDecode(r.body) as Map;
            return http.Response(
              jsonEncode({
                'choices': [
                  {
                    'message': {'content': 'fixture reply'},
                  },
                ],
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }),
        ),
      );
      await store.restore();
      store.role.prompt = 'Act as {{char}} and greet {{user}}';
      store.role.card = {
        '角色描述': 'fixture description',
        '示例对话': 'fixture dialogue',
        '开场白': 'not a system instruction',
      };
      store.userCard = {'称呼': 'fixture user', '交流边界': 'fixture boundary'};
      expect(store.send('fixture message'), isTrue);
      await waitForReply(store);
      final system = (body!['messages'] as List).first['content'] as String;
      expect(system, contains('fixture description'));
      expect(system, contains('fixture boundary'));
      expect(system, isNot(contains('{{user}}')));
      final restored = DemoStore(
        settings: TestModels(),
        storage: MemoryChats(),
      );
      await restored.restore();
      await restored.importChats(store.exportChats());
      expect(restored.userCard, store.userCard);
      expect(restored.role.card, store.role.card);
      store.dispose();
      restored.dispose();
    },
  );
}

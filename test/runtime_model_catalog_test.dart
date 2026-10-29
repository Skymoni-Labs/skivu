import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ski/chat_api.dart';
import 'package:ski/local_runtime_models.dart';
import 'package:ski/model_connection.dart';
import 'package:ski/model_settings.dart';
import 'package:ski/relay_account.dart';
import 'relay_account_test.dart' show AccountPlatform;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late RelayAccount account;
  late ModelSettings custom;
  final requests = <http.Request>[];
  const customConfig = ModelConnection(
    id: 'personal',
    name: 'My model',
    provider: 'custom',
    protocol: ApiProtocol.chat,
    address: 'https://private-provider.example/v1',
    model: 'mine',
  );
  setUp(() async {
    requests.clear();
    FlutterSecureStorage.setMockInitialValues({
      'skivu.relay.account.v1': jsonEncode({
        'token': 'synthetic-account-token',
        'expires': DateTime.now()
            .add(const Duration(hours: 1))
            .millisecondsSinceEpoch,
        'model': 'first',
      }),
      'skivu.api.personal': 'synthetic-custom-key',
    });
    account = RelayAccount(
      platform: AccountPlatform(),
      clientFactory: () => MockClient((request) async {
        requests.add(request);
        return http.Response(
          '{"choices":[{"message":{"role":"assistant","content":"ok"}}]}',
          200,
        );
      }),
    );
    await account.restore();
    account.user = {'id': 7};
    account.models = ['first', 'second', 'responses-only'];
    account.protocols = {
      'first': 'chat',
      'second': 'chat',
      'responses-only': 'responses',
    };
    custom = ModelSettings()
      ..connections.add(customConfig)
      ..activeId = 'personal';
  });
  tearDown(() {
    account.dispose();
    custom.dispose();
  });
  test(
    'imports all published account models and saved custom labels without secrets',
    () {
      final catalog = LocalRuntimeModels(
        account: account,
        custom: custom,
        useAccount: true,
      );
      final rows = catalog.list();
      expect(rows.map((r) => r['id']), [
        'account:first',
        'account:second',
        'account:responses-only',
        'custom:personal',
      ]);
      expect(rows[2]['supportsTools'], false);
      final serialized = jsonEncode(rows);
      for (final secret in [
        'synthetic-account-token',
        'synthetic-custom-key',
        'private-provider.example',
        'credentialId',
      ]) {
        expect(serialized, isNot(contains(secret)));
      }
    },
  );
  test(
    'catalog selection keeps account model and funding host owned',
    () async {
      final catalog = LocalRuntimeModels(
        account: account,
        custom: custom,
        useAccount: true,
      );
      final selected = await catalog.open('account:second');
      await selected.send(
        messages: [
          {'role': 'user', 'content': 'hello'},
        ],
        tools: [],
      );
      expect(account.activeModel, 'first');
      expect(jsonDecode(requests.single.body)['model'], 'second');
      expect(
        requests.single.url.path,
        '/api/app-account/agent/chat/completions',
      );
      expect(
        requests.single.headers['authorization'],
        'AppAccount synthetic-account-token',
      );
      account.models.remove('second');
      await expectLater(
        catalog.open('account:second'),
        throwsA(
          isA<ChatFailure>().having(
            (e) => e.code,
            'code',
            'model_not_available',
          ),
        ),
      );
      await expectLater(
        catalog.open('https://attacker.example'),
        throwsA(isA<ChatFailure>()),
      );
      await expectLater(
        catalog.open('account:responses-only'),
        throwsA(isA<ChatFailure>()),
      );
      expect(requests.length, 1);
    },
  );
  test(
    'funding or saved custom configuration changes invalidate the session',
    () {
      final catalog = LocalRuntimeModels(
        account: account,
        custom: custom,
        useAccount: true,
      );
      account.funding = 'beta';
      expect(catalog.valid, false);
      account.funding = 'relay';
      expect(catalog.valid, true);
      custom.connections.clear();
      expect(catalog.valid, false);
      expect(catalog.list, throwsA(isA<ChatFailure>()));
    },
  );
  test(
    'custom structured chat uses host credentials without account funding or redirects',
    () async {
      final client = MockClient((request) async {
        expect(
          request.url.toString(),
          'https://private-provider.example/v1/chat/completions',
        );
        expect(request.headers['authorization'], 'Bearer synthetic-custom-key');
        expect(request.followRedirects, false);
        final body = jsonDecode(request.body) as Map;
        expect(body.containsKey('funding'), false);
        expect(body['model'], 'mine');
        expect(body['stream'], false);
        return http.Response('{"choices":[{"message":{"content":"ok"}}]}', 200);
      });
      final result =
          await AgentChatSession.custom(
            client,
            customConfig,
            'synthetic-custom-key',
          ).send(
            messages: [
              {'role': 'user', 'content': 'hi'},
            ],
            tools: [],
          );
      expect(jsonEncode(result), isNot(contains('synthetic-custom-key')));
    },
  );
}

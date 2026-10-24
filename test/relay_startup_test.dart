import 'dart:async';
import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ski/relay_account.dart';
import 'package:ski/state.dart';
import 'real_chat_store_test.dart' show MemoryChats;
import 'relay_account_test.dart' show AccountPlatform, ok, me, catalog;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  void stored() => FlutterSecureStorage.setMockInitialValues({
    'skivu.relay.account.v1': jsonEncode({
      'token': 'fixture-token',
      'expires': DateTime.now()
          .add(const Duration(hours: 1))
          .millisecondsSinceEpoch,
      'model': 'chat-fixture',
    }),
  });
  test(
    'legacy beta archive restores locally before a hanging profile sync',
    () async {
      stored();
      var calls = 0;
      final pending = Completer<http.Response>();
      final account = RelayAccount(
        platform: AccountPlatform(),
        clientFactory: () => MockClient((_) {
          calls++;
          return pending.future;
        }),
      );
      await account.restore();
      final disk = MemoryChats();
      final store = DemoStore(storage: disk, account: account);
      disk.data = jsonEncode({
        ...jsonDecode(store.exportChats()) as Map,
        'useBeta': true,
      });
      await store.restore().timeout(const Duration(milliseconds: 200));
      expect(calls, 0);
      expect(store.useAccount, isTrue);
      expect(account.funding, 'beta');
      expect(account.canChat, isFalse);
      final refreshing = account.refresh();
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);
      pending.complete(http.Response('expired', 401));
      await refreshing;
      store.dispose();
      account.dispose();
    },
  );
  test(
    'local restore never starts HTTP; background refresh notifies on completion',
    () async {
      stored();
      final pending = Completer<http.Response>();
      var calls = 0;
      var notices = 0;
      final account = RelayAccount(
        platform: AccountPlatform(),
        clientFactory: () => MockClient((r) async {
          calls++;
          return r.url.path.endsWith('/me') ? pending.future : ok(catalog());
        }),
      );
      account.addListener(() => notices++);
      await account.restore().timeout(const Duration(milliseconds: 200));
      expect(calls, 0);
      expect(account.signedIn, isTrue);
      expect(account.canChat, isFalse);
      final refreshing = account.refresh();
      await Future<void>.delayed(Duration.zero);
      expect(account.busy, isTrue);
      expect(account.canChat, isFalse);
      final before = notices;
      pending.complete(ok(me()));
      await refreshing;
      expect(account.canChat, isTrue);
      expect(account.busy, isFalse);
      expect(notices, greaterThan(before));
      account.dispose();
    },
  );
  test('whole refresh deadline bounds a hanging model catalog', () async {
    stored();
    final never = Completer<http.Response>();
    final account = RelayAccount(
      platform: AccountPlatform(),
      syncTimeout: const Duration(milliseconds: 60),
      clientFactory: () => MockClient((r) async {
        if (r.url.path.endsWith('/me')) {
          await Future<void>.delayed(const Duration(milliseconds: 30));
          return ok(me());
        }
        return never.future;
      }),
    );
    await account.restore();
    await account.refresh().timeout(const Duration(milliseconds: 180));
    expect(account.busy, isFalse);
    expect(account.canChat, isFalse);
    expect(account.user, isNotNull);
    expect(account.models, isEmpty);
    never.complete(ok(catalog()));
    await Future<void>.delayed(Duration.zero);
    expect(account.canChat, isFalse);
    account.dispose();
  });
  test(
    '401 without JSON invalidates local session and releases busy',
    () async {
      stored();
      final account = RelayAccount(
        platform: AccountPlatform(),
        clientFactory: () =>
            MockClient((_) async => http.Response('expired', 401)),
      );
      await account.restore();
      await account.refresh();
      expect(account.signedIn, isFalse);
      expect(account.busy, isFalse);
      expect(account.canChat, isFalse);
      account.dispose();
    },
  );
  test(
    'late refresh cannot restore a logged out account or replace a new account',
    () async {
      stored();
      final pending = Completer<http.Response>();
      var old = true;
      final account = RelayAccount(
        platform: AccountPlatform(),
        clientFactory: () => MockClient((r) async {
          if (r.method == 'DELETE') return ok({});
          if (old && r.url.path.endsWith('/me')) return pending.future;
          if (r.url.path.endsWith('/options'))
            return ok({
              'password_login_enabled': true,
              'encryption': {'enabled': false},
            });
          if (r.url.path.endsWith('/login'))
            return ok({
              'access_token': 'new-fixture',
              'token_type': 'AppAccount',
              'expires_at':
                  DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
            });
          if (r.url.path.endsWith('/me'))
            return ok({
              ...me(),
              'user': {'id': 99},
            });
          return ok(catalog());
        }),
      );
      await account.restore();
      final refreshing = account.refresh();
      await Future<void>.delayed(Duration.zero);
      await account.logout();
      expect(account.canChat, isFalse);
      old = false;
      await account.signIn('fixture', 'fixture');
      expect(account.user?['id'], 99);
      pending.complete(ok(me()));
      await refreshing;
      expect(account.user?['id'], 99);
      expect(account.canChat, isTrue);
      account.dispose();
    },
  );
  test(
    'session expiry while profile is pending cannot publish models',
    () async {
      stored();
      final pending = Completer<http.Response>();
      final account = RelayAccount(
        platform: AccountPlatform(),
        clientFactory: () => MockClient((_) => pending.future),
      );
      await account.restore();
      final refreshing = account.refresh();
      await Future<void>.delayed(Duration.zero);
      account.expiresAt = DateTime.now().subtract(const Duration(seconds: 1));
      pending.complete(ok(me()));
      await refreshing;
      expect(account.user, isNull);
      expect(account.models, isEmpty);
      expect(account.busy, isFalse);
      account.dispose();
    },
  );
}

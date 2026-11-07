import 'dart:async';
import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ski/model_settings.dart';
import 'package:ski/relay_account.dart';
import 'package:ski/state.dart';
import 'real_chat_store_test.dart' show MemoryChats, waitForReply;
import 'relay_account_test.dart'
    show AccountPlatform, ok, failure, authorization, token, me, catalog;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test(
    'completed reply keeps selected model label while automatic catalog refresh is pending',
    () async {
      final pendingCatalog = Completer<http.Response>();
      final refreshingCatalog = Completer<void>();
      var afterReply = false, chatCalls = 0;
      final account = RelayAccount(
        platform: AccountPlatform(),
        clientFactory: () => MockClient((request) async {
          if (request.url.path.endsWith('/authorize'))
            return ok(authorization());
          if (request.url.path.endsWith('/token')) return ok(token());
          if (request.url.path.endsWith('/me')) return ok(me());
          if (request.url.path.endsWith('/models')) {
            if (afterReply) {
              if (!refreshingCatalog.isCompleted) refreshingCatalog.complete();
              return pendingCatalog.future;
            }
            return ok(catalog());
          }
          expect(request.url.path, '/api/app-account/chat/completions');
          chatCalls++;
          afterReply = true;
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': 'completed answer'},
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
      final store = DemoStore(
        account: account,
        settings: models,
        storage: MemoryChats(),
      )..useAccount = true;
      final visibleLabels = <String>[];
      store.addListener(() => visibleLabels.add(store.model));
      try {
        expect(store.model, 'chat-fixture');
        expect(store.send('hello'), isTrue);
        await refreshingCatalog.future.timeout(const Duration(seconds: 2));
        await waitForReply(store);
        expect(store.messages.last.status, 'complete');
        expect(store.messages.last.text, 'completed answer');
        expect(account.signedIn, isTrue);
        expect(account.busy, isTrue);
        expect(account.models, isEmpty);
        expect(
          store.activeConnection,
          isNull,
          reason: 'Pending catalog cannot authorize a new request',
        );
        expect(store.model, 'chat-fixture');
        expect(visibleLabels, isNot(contains('登录中转站')));
        final count = store.messages.length;
        expect(store.send('must wait'), isFalse);
        expect(store.messages.length, count);
        expect(store.lastError, contains('同步'));
        expect(store.lastError, isNot(contains('登录')));
        expect(chatCalls, 1);
        pendingCatalog.complete(ok(catalog()));
        for (var i = 0; i < 100 && account.busy; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(account.canChat, isTrue);
        expect(store.model, 'chat-fixture');
        expect(visibleLabels, isNot(contains('登录中转站')));
      } finally {
        if (!pendingCatalog.isCompleted) pendingCatalog.complete(ok(catalog()));
        for (var i = 0; i < 100 && account.busy; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        store.dispose();
        models.dispose();
        account.dispose();
      }
    },
  );

  test(
    'catalog denial is not logout, empty catalog is not login, real invalidation still clears model',
    () async {
      var mode = 'ready', chatCalls = 0;
      final account = RelayAccount(
        platform: AccountPlatform(),
        clientFactory: () => MockClient((request) async {
          if (request.url.path.endsWith('/authorize'))
            return ok(authorization());
          if (request.url.path.endsWith('/token')) return ok(token());
          if (request.url.path.endsWith('/me')) {
            return mode == 'revoked'
                ? failure('APP_SESSION_INVALID', 401)
                : ok(me());
          }
          if (request.url.path.endsWith('/models')) {
            if (mode == 'denied') return failure('MODEL_NOT_AVAILABLE', 403);
            return ok(
              mode == 'empty'
                  ? {'models': [], 'model_protocols': {}}
                  : catalog(),
            );
          }
          chatCalls++;
          throw StateError('No generation allowed');
        }),
      );
      await account.beginAuthorization();
      await account.pollAuthorization();
      final models = ModelSettings();
      final store = DemoStore(
        account: account,
        settings: models,
        storage: MemoryChats(),
      )..useAccount = true;
      try {
        mode = 'denied';
        await account.refresh();
        expect(account.signedIn, isTrue);
        expect(account.canChat, isFalse);
        expect(store.model, 'chat-fixture');
        expect(store.send('blocked'), isFalse);
        expect(store.lastError, contains('模型'));
        expect(store.lastError, isNot(contains('登录')));
        mode = 'empty';
        await account.refresh();
        expect(account.signedIn, isTrue);
        expect(store.model, '选择模型');
        expect(store.activeConnection, isNull);
        mode = 'ready';
        await account.refresh();
        expect(store.model, 'chat-fixture');
        mode = 'revoked';
        await account.refresh();
        expect(account.signedIn, isFalse);
        expect(account.activeModel, isNull);
        expect(store.model, '登录中转站');
        expect(store.send('blocked after revocation'), isFalse);
        expect(chatCalls, 0);
      } finally {
        store.dispose();
        models.dispose();
        account.dispose();
      }
    },
  );
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ski/chat_api.dart';
import 'package:ski/state.dart';
import 'package:ski/ui_host_binding.dart';
import 'package:ski/ui_plugins.dart';
import 'real_chat_store_test.dart' show MemoryChats, TestModels, waitForReply;
import 'chat_api_test.dart' show sse;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final mode in [ChatUiMode.wechat, ChatUiMode.qq]) {
    test(
      '${mode.name} requests a full reply and never projects a pending bubble',
      () async {
        final response = Completer<http.Response>();
        final requested = Completer<Map<String, dynamic>>();
        final models = TestModels();
        final original = models.connections.single;
        final store = DemoStore(
          storage: MemoryChats(),
          settings: models,
          api: ChatApi(
            clientFactory: () => MockClient((r) {
              requested.complete(jsonDecode(r.body) as Map<String, dynamic>);
              return response.future;
            }),
          ),
        );
        await store.restore();
        store.newChat();
        final host = UiHostBinding(store);
        expect(
          host.mutate({
            'protocol': 1,
            'command': 'send',
            'chatId': host.selected.id,
            'revision': 1,
            'text': 'whole reply',
          }, mode: mode),
          isNull,
        );
        expect((await requested.future)['stream'], isFalse);
        // Some providers still deliver partial text: it must not cross the bridge.
        store.messages.last.text = 'partial';
        final waiting = host.snapshot(mode, force: true);
        expect(waiting['streaming'], isTrue);
        expect(waiting['messages'], hasLength(1));
        expect(jsonEncode(waiting), isNot(contains('partial')));
        store.messages.last.text = '';
        response.complete(
          http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'role': 'assistant', 'content': 'complete reply'},
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          ),
        );
        await waitForReply(store);
        final done = host.snapshot(mode);
        expect(done['streaming'], isFalse);
        expect((done['messages'] as List).last['text'], 'complete reply');
        expect(models.connections.single, same(original));
        expect(original.streaming, isTrue);
        store.dispose();
      },
    );
  }
  test('the packaged styling is exactly the approved comparison styling', () {
    final source =
        jsonDecode(File('assets/social_ui/PROVENANCE.json').readAsStringSync())
            as Map;
    for (final name in ['social.css', 'native.css', 'vendor/weui-light.css']) {
      expect(
        sha256
            .convert(File('assets/social_ui/$name').readAsBytesSync())
            .toString(),
        source['files'][name],
        reason: name,
      );
    }
  });
  test(
    'shared roles, independent contexts and delayed old-page sends stay isolated',
    () async {
      final requests = <Map<String, dynamic>>[];
      final store = DemoStore(
        storage: MemoryChats(),
        settings: TestModels(),
        api: ChatApi(
          clientFactory: () => MockClient((r) async {
            requests.add(jsonDecode(r.body) as Map<String, dynamic>);
            return http.Response(
              sse([
                {
                  'choices': [
                    {
                      'delta': {'content': '本机验收'},
                    },
                  ],
                },
                '[DONE]',
              ]),
              200,
              headers: {'content-type': 'text/event-stream'},
            );
          }),
        ),
      );
      await store.restore();
      final role = store.personas.first..prompt = 'PRIVATE_SYSTEM_CARD';
      final host = UiHostBinding(store);
      store.newChat(personaId: role.id);
      final first = host.selected;
      expect(
        host.mutate({
          'protocol': 1,
          'command': 'send',
          'chatId': first.id,
          'revision': 1,
          'text': 'only first',
        }),
        isNull,
      );
      await waitForReply(store);
      store.newChat(personaId: role.id);
      final second = host.selected;
      expect(
        host.mutate({
          'protocol': 1,
          'command': 'send',
          'chatId': first.id,
          'revision': 2,
          'text': 'must not reach second',
        }),
        isNotNull,
      );
      expect(requests, hasLength(1));
      expect(second.messages, isEmpty);
      expect(
        host.mutate({
          'protocol': 1,
          'command': 'send',
          'chatId': second.id,
          'revision': 1,
          'text': 'only second',
        }),
        isNull,
      );
      await waitForReply(store);
      expect(
        jsonEncode(requests.last['messages']),
        isNot(contains('only first')),
      );
      expect(
        jsonEncode(requests.last['messages']),
        isNot(contains('must not reach second')),
      );
      expect(
        jsonEncode(requests.last['messages']),
        contains('PRIVATE_SYSTEM_CARD'),
      );
      final snapshot = host.snapshot(ChatUiMode.wechat, force: true);
      expect(snapshot['chats'], hasLength(2));
      expect(snapshot['roles'], hasLength(store.personas.length));
      expect(jsonEncode(snapshot), isNot(contains('PRIVATE_SYSTEM_CARD')));
      expect(jsonEncode(snapshot), isNot(contains('test-key-only')));
      role.name = '同步名字';
      store.changed();
      expect(
        (host.snapshot(ChatUiMode.qq)['roles'] as List).first['name'],
        '同步名字',
      );
      expect(first.messages.first.text, 'only first');
      await store.saveChats();
      store.dispose();
    },
  );
  test(
    'stale drafts and stale message indices cannot overwrite current data',
    () async {
      final store = DemoStore(storage: MemoryChats());
      await store.restore();
      store.newChat();
      final host = UiHostBinding(store), id = store.conversations.first.id;
      host.mutate({
        'protocol': 1,
        'command': 'draft',
        'chatId': id,
        'revision': 4,
        'text': 'latest draft',
      });
      host.mutate({
        'protocol': 1,
        'command': 'draft',
        'chatId': id,
        'revision': 3,
        'text': 'late old draft',
      });
      expect(host.selected.draft, 'latest draft');
      final m = Message(false, 'message');
      host.selected.messages.add(m);
      expect(
        host.messageFor({
          'chatId': id,
          'index': 0,
          'created': m.created.toIso8601String(),
        }),
        same(m),
      );
      expect(
        host.messageFor({
          'chatId': id,
          'index': 0,
          'created': 'wrong timestamp',
        }),
        isNull,
      );
      expect(
        host.valid({'protocol': 1, 'command': 'executeJavascript'}),
        isFalse,
      );
      store.dispose();
    },
  );
  test(
    'mode application and restore never copy, merge or change chat archives',
    () async {
      final disk = MemoryChats(), store = DemoStore(storage: MemoryChats());
      await store.restore();
      final role = store.personas.first;
      store.newChat(personaId: role.id);
      final first = store.conversations.first;
      first.messages.add(Message(true, 'one'));
      store.newChat(personaId: role.id);
      store.messages.add(Message(true, 'two'));
      final before = store.exportChats();
      final settings = UiPluginSettings();
      await settings.apply(ChatUiMode.wechat);
      await settings.apply(ChatUiMode.qq);
      expect(store.exportChats(), before);
      final restored = UiPluginSettings();
      await restored.restore();
      expect(restored.mode, ChatUiMode.qq);
      await disk.write(before);
      final other = DemoStore(storage: disk);
      await other.restore();
      expect(other.conversationsFor(role.id), hasLength(2));
      expect(other.messages.single.text, 'two');
      settings.dispose();
      restored.dispose();
      store.dispose();
      other.dispose();
    },
  );
}

import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ski/chat_api.dart';
import 'package:ski/state.dart';
import 'package:ski/ui_host_binding.dart';
import 'package:ski/ui_plugins.dart';
import 'real_chat_store_test.dart' show MemoryChats, TestModels, waitForReply;

http.Response reply([int status = 200]) => http.Response(
  jsonEncode({
    'choices': [
      {
        'message': {'content': 'Unread QA reply'},
        'finish_reason': 'stop',
      },
    ],
  }),
  status,
  headers: {'content-type': 'application/json'},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'completed hidden reply is counted once, persisted, and cleared only by its reader',
    () async {
      final storage = MemoryChats(), response = Completer<http.Response>();
      final store = DemoStore(
        storage: storage,
        settings: TestModels(),
        api: ChatApi(clientFactory: () => MockClient((_) => response.future)),
      );
      addTearDown(store.dispose);
      await store.restore();
      store.newChat();
      final chat = store.conversations.first;
      expect(store.send('QA', streamingOverride: false), isTrue);
      expect(chat.unreadCount, 0);
      response.complete(reply());
      await waitForReply(store);
      expect(chat.unreadCount, 1);
      store.changed();
      store.changed();
      expect(chat.unreadCount, 1);
      final host = UiHostBinding(store);
      expect(
        (host.snapshot(ChatUiMode.wechat, force: true)['chats'] as List)
            .single['unread'],
        1,
      );
      await store.saveChats();
      final restored = DemoStore(storage: storage, settings: TestModels());
      addTearDown(restored.dispose);
      await restored.restore();
      expect(restored.conversations.single.unreadCount, 1);
      final owner = Object();
      restored.setChatReader(owner, 'another-chat');
      expect(restored.conversations.single.unreadCount, 1);
      restored.setChatReader(owner, chat.id);
      expect(restored.conversations.single.unreadCount, 0);
      await restored.saveChats();
      expect(
        (jsonDecode(storage.data!)['conversations'][0]['messages'] as List)
            .last['unread'],
        false,
      );
    },
  );

  for (final situation in ['reading', 'left-chat', 'background']) {
    test('$situation completion respects the actual reading surface', () async {
      final response = Completer<http.Response>();
      final store = DemoStore(
        storage: MemoryChats(),
        settings: TestModels(),
        api: ChatApi(clientFactory: () => MockClient((_) => response.future)),
      );
      addTearDown(store.dispose);
      await store.restore();
      store.newChat();
      final chat = store.conversations.first, owner = Object();
      store.setChatReader(owner, chat.id);
      store.send('QA', streamingOverride: false);
      if (situation == 'left-chat') store.setChatReader(owner, null);
      if (situation == 'background') store.setChatForeground(false);
      response.complete(reply());
      await waitForReply(store);
      expect(chat.unreadCount, situation == 'reading' ? 0 : 1);
      if (situation == 'background') {
        store.setChatForeground(true);
        expect(chat.unreadCount, 0);
      }
    });
  }

  test('failures and interrupted replies never create unread alerts', () async {
    final store = DemoStore(
      storage: MemoryChats(),
      settings: TestModels(),
      api: ChatApi(clientFactory: () => MockClient((_) async => reply(500))),
    );
    addTearDown(store.dispose);
    await store.restore();
    store.newChat();
    store.send('QA', streamingOverride: false);
    await waitForReply(store);
    expect(store.messages.last.status, 'failed');
    expect(store.conversations.first.unreadCount, 0);
    final interrupted = Message(false, 'partial')
      ..status = 'pending'
      ..unread = true;
    expect(Message.fromJson(interrupted.toJson()).unread, false);
  });

  test(
    'legacy history and outgoing messages do not become unread on upgrade',
    () {
      final old = Message(false, 'historic').toJson()..remove('unread');
      expect(Message.fromJson(old).unread, false);
      final outgoing = Message(true, 'outgoing').toJson()..['unread'] = true;
      expect(Message.fromJson(outgoing).unread, false);
    },
  );
}

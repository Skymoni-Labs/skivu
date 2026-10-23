import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ski/state.dart';
import 'package:ski/ui_host_binding.dart';
import 'package:ski/ui_plugins.dart';
import 'real_chat_store_test.dart' show MemoryChats;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'chat settings persist per conversation without changing the shared role',
    () async {
      final disk = MemoryChats(), store = DemoStore(storage: MemoryChats());
      await store.restore();
      final role = store.personas.first, host = UiHostBinding(store);
      store.newChat(personaId: role.id);
      final first = host.selected;
      final card = role.compiledPrompt;
      for (final key in ['pinned', 'muted', 'replyReminder']) {
        expect(
          host.mutate({
            'protocol': 1,
            'command': 'chatOptions',
            'chatId': first.id,
            'key': key,
            'value': true,
          }),
          isNull,
        );
      }
      const background = 'data:image/png;base64,AAAA';
      // Preserve an old per-chat image in exported archives, but never expose
      // or mutate it as the shared original appearance configuration.
      first.chatBackground = background;
      store.newChat(personaId: role.id);
      final second = host.selected;
      expect(second.pinned, isFalse);
      expect(second.muted, isFalse);
      expect(second.replyReminder, isFalse);
      expect(second.chatBackground, isNull);
      expect(
        host.mutate({
          'protocol': 1,
          'command': 'chatOptions',
          'chatId': first.id,
          'key': 'muted',
          'value': false,
        }),
        isNotNull,
      );
      expect(first.muted, isTrue);
      expect(role.compiledPrompt, card);
      expect(
        jsonEncode(host.snapshot(ChatUiMode.wechat)),
        isNot(contains(background)),
      );
      await disk.write(store.exportChats());
      final restored = DemoStore(storage: disk);
      await restored.restore();
      final copy = restored.conversations.firstWhere((c) => c.id == first.id);
      expect(copy.pinned, isTrue);
      expect(copy.muted, isTrue);
      expect(copy.replyReminder, isTrue);
      expect(copy.chatBackground, background);
      store.dispose();
      restored.dispose();
    },
  );
  test(
    'unsupported preferences and external/SVG/oversized backgrounds are rejected',
    () async {
      final store = DemoStore(storage: MemoryChats());
      await store.restore();
      store.newChat();
      final host = UiHostBinding(store);
      for (final value in [
        'https://example.com/private.png',
        'data:image/svg+xml;base64,AAAA',
        'data:image/png;base64,${'A' * 180000}',
      ]) {
        expect(
          host.mutate({
            'protocol': 1,
            'command': 'chatOptions',
            'chatId': host.selected.id,
            'key': 'background',
            'value': value,
          }),
          isNotNull,
        );
      }
      expect(
        host.mutate({
          'protocol': 1,
          'command': 'chatOptions',
          'chatId': host.selected.id,
          'key': 'unknown',
          'value': true,
        }),
        isNotNull,
      );
      final legacy = Conversation.fromJson({'title': '旧对话', 'messages': []});
      expect(legacy.muted, isFalse);
      expect(legacy.replyReminder, isFalse);
      expect(legacy.chatBackground, isNull);
      store.dispose();
    },
  );
  test(
    'clearing and undo affect only one conversation and never duplicate messages',
    () async {
      final store = DemoStore(storage: MemoryChats());
      await store.restore();
      final role = store.personas.first;
      store.newChat(personaId: role.id);
      final first = store.conversations[store.conversation];
      first.messages.add(Message(true, '保留旧消息'));
      first.usedTokens = 10;
      first.pinned = true;
      first.muted = true;
      first.draft = '草稿';
      store.newChat(personaId: role.id);
      final second = store.conversations[store.conversation];
      second.messages.add(Message(true, '另一段独立消息'));
      final backup = store.clearChatMessages(first.id)!;
      expect(first.messages, isEmpty);
      expect(first.draft, '草稿');
      expect(first.pinned, isTrue);
      expect(first.muted, isTrue);
      expect(first.personaId, role.id);
      expect(first.usedTokens, 0);
      expect(second.messages.single.text, '另一段独立消息');
      first.messages.add(Message(true, '清空后的新消息'));
      first.usedTokens = 5;
      expect(store.restoreClearedMessages(backup), isTrue);
      expect(first.messages.map((m) => m.text), ['保留旧消息', '清空后的新消息']);
      expect(first.usedTokens, 15);
      expect(store.restoreClearedMessages(backup), isFalse);
      expect(first.messages, hasLength(2));
      expect(store.conversations[store.conversation], same(second));
      store.dispose();
    },
  );
}

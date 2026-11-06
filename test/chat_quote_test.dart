import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ski/chat_api.dart';
import 'package:ski/chat_quote.dart';
import 'package:ski/state.dart';
import 'real_chat_store_test.dart' show MemoryChats, TestModels, waitForReply;

void main() {
  test(
    'references preserve typed draft, deduplicate and survive restart',
    () async {
      final disk = MemoryChats();
      final store = DemoStore(storage: disk);
      await store.restore();
      final chat = store.conversations.first;
      final source = Message(false, '需要引用的完整内容');
      chat.messages.add(source);
      store.saveDraft(chat, '已经输入的草稿');
      store.quoteMessage(chat, source);
      store.quoteMessage(chat, source);
      expect(chat.draft, '已经输入的草稿');
      expect(chat.draftQuotes.single.messageId, source.id);
      final other = Conversation('另一会话', [Message(false, '其他内容')]);
      store.conversations.add(other);
      store.quoteMessage(other, source);
      expect(other.draftQuotes, isEmpty);
      await store.saveChats();
      store.dispose();
      final restored = DemoStore(storage: disk);
      await restored.restore();
      final saved = restored.conversations.first;
      expect(saved.messages.single.id, source.id);
      expect(saved.draft, '已经输入的草稿');
      expect(saved.draftQuotes.single.text, source.text);
      restored.removeDraftQuote(saved, source.id);
      expect(saved.draftQuotes, isEmpty);
      expect(saved.draft, '已经输入的草稿');
      await restored.saveChats();
      restored.dispose();
    },
  );

  test(
    'queued references stay separate and unrelated sends preserve draft references',
    () async {
      final store = DemoStore(storage: MemoryChats());
      await store.restore();
      final chat = store.conversations.first..confirmBeforeReply = true;
      final source = Message(false, '引用快照');
      chat.messages.add(source);
      store.quoteMessage(chat, source);
      final quote = chat.draftQuotes.single;
      expect(store.send('普通的其他入口消息'), isTrue);
      expect(chat.draftQuotes, [quote]);
      expect(chat.queuedMessages.single.quotes, isEmpty);
      expect(store.send('带引用的问题', quotes: [quote]), isTrue);
      expect(chat.draftQuotes, isEmpty);
      final sent = chat.queuedMessages.last;
      expect(sent.text, '带引用的问题');
      expect(sent.quotes.single.text, source.text);
      source.text = '后来编辑过的原文';
      expect(sent.quotes.single.text, '引用快照');
      expect(store.confirmPending(), isFalse);
      expect(chat.queuedMessages.last.quotes.single, same(quote));
      await store.saveChats();
      store.dispose();
    },
  );

  test(
    'API receives reference context while visible sent text remains compact',
    () async {
      Map? body;
      final models = TestModels();
      final store = DemoStore(
        storage: MemoryChats(),
        settings: models,
        api: ChatApi(
          clientFactory: () => MockClient((request) async {
            body = jsonDecode(request.body) as Map;
            return http.Response(
              jsonEncode({
                'choices': [
                  {
                    'message': {'content': '已回答'},
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
      final chat = store.conversations.first;
      final source = Message(false, '指定的原文');
      chat.messages.add(source);
      store.quoteMessage(chat, source);
      expect(
        store.send(
          '请解释',
          quotes: List.of(chat.draftQuotes),
          streamingOverride: false,
        ),
        isTrue,
      );
      await waitForReply(store);
      final requestUser = (body!['messages'] as List).lastWhere(
        (m) => m['role'] == 'user',
      );
      expect(requestUser['content'], contains('指定的原文'));
      expect(requestUser['content'], contains('［本条消息］\n请解释'));
      final sent = chat.messages.firstWhere((m) => m.user);
      expect(sent.text, '请解释');
      expect(sent.quotes.single.messageId, source.id);
      expect(chat.draftQuotes, isEmpty);
      expect(store.messages.last.text, '已回答');
      await store.saveChats();
      store.dispose();
      models.dispose();
    },
  );

  test('old message format and malformed references restore safely', () {
    final old = Message.fromJson({'user': false, 'text': '旧消息'});
    expect(old.id, isNotEmpty);
    expect(old.quotes, isEmpty);
    expect(Message.fromJson(old.toJson()).id, old.id);
    expect(
      ChatQuote.parseList([
        null,
        {},
        {'chatId': 1},
      ]),
      isEmpty,
    );
  });
}

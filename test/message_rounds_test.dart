import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ski/chat_api.dart';
import 'package:ski/state.dart';
import 'real_chat_store_test.dart' show MemoryChats, TestModels, waitForReply;

void main() {
  test(
    'round deletion preserves other turns, chats and drafts; request and restart omit it',
    () async {
      final disk = MemoryChats(), models = TestModels();
      final requests = <Map>[];
      final api = ChatApi(
        clientFactory: () => MockClient((request) async {
          requests.add(jsonDecode(request.body) as Map);
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': '继续回复'},
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      final store = DemoStore(storage: disk, settings: models, api: api);
      await store.restore();
      final first = Message(true, '第一问'), answer = Message(false, '第一答');
      final extra = Message(false, '第一答补充');
      final second = Message(true, '第二问'), kept = Message(false, '第二答');
      store.messages.addAll([first, answer, extra, second, kept]);
      final target = store.conversations.first;
      target.draft = '保留草稿';
      target.usedTokens = 42;
      final other = Conversation('另一段对话', [
        Message(false, '其他记录'),
      ], personaId: store.personas.last.id);
      store.conversations.add(other);
      expect(store.roundMessages(target.id, answer), [first, answer, extra]);
      expect(store.deleteRound(target.id, answer), isTrue);
      expect(store.messages, [second, kept]);
      expect(target.draft, '保留草稿');
      expect(target.usedTokens, 42);
      expect(other.messages.single.text, '其他记录');
      expect(store.deleteRound(target.id, answer), isFalse);
      expect(store.send('第三问'), isTrue);
      await waitForReply(store);
      final request = jsonEncode(requests.single['messages']);
      expect(request, isNot(contains('第一问')));
      expect(request, isNot(contains('第一答')));
      expect(request, contains('第二问'));
      expect(request, contains('第二答'));
      await store.saveChats();
      store.dispose();
      final restored = DemoStore(storage: disk, settings: models);
      await restored.restore();
      expect(restored.messages.map((m) => m.text), [
        '第二问',
        '第二答',
        '第三问',
        '继续回复',
      ]);
      expect(restored.conversations.first.draft, '保留草稿');
      expect(restored.conversations.last.messages.single.text, '其他记录');
      restored.dispose();
      models.dispose();
    },
  );
  test(
    'deleting a generating round cancels it and late preparation cannot restore it',
    () async {
      final models = TestModels()..pendingKey = Completer<String>();
      var requests = 0;
      final store = DemoStore(
        storage: MemoryChats(),
        settings: models,
        api: ChatApi(
          clientFactory: () => MockClient((_) async {
            requests++;
            throw StateError('Cancelled round must not make a request');
          }),
        ),
      );
      await store.restore();
      store.send('待生成的提问');
      final answer = store.messages.last;
      expect(store.streaming, isTrue);
      expect(store.deleteRound(store.conversations.first.id, answer), isTrue);
      expect(store.streaming, isFalse);
      expect(answer.status, 'cancelled');
      models.pendingKey!.complete('fixture-key');
      await Future<void>.delayed(const Duration(milliseconds: 25));
      expect(store.messages, isEmpty);
      expect(requests, 0);
      store.dispose();
      models.dispose();
    },
  );
}

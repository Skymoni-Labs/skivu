import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ski/chat_api.dart';
import 'package:ski/chat_storage.dart';
import 'package:ski/model_settings.dart';
import 'package:ski/state.dart';
import 'chat_api_test.dart' show connection, sse;
import 'package:ski/model_connection.dart';

class MemoryChats extends ChatStorage {
  String? data;
  bool failing = false;
  @override
  Future<String?> read() async => data;
  @override
  Future<void> write(String value) async {
    if (failing) throw StateError('full');
    data = value;
  }
}

class TestModels extends ModelSettings {
  Completer<String>? pendingKey;
  TestModels() {
    final c = connection(ApiProtocol.chat);
    connections.add(c);
    activeId = c.id;
  }
  @override
  Future<String> keyFor(String id) async =>
      pendingKey == null ? 'test-key-only' : pendingKey!.future;
}

Future<void> waitForReply(DemoStore store) async {
  for (var i = 0; i < 100 && store.streaming; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  expect(store.streaming, isFalse);
}

void main() {
  test(
    'multi-turn chat uses real response and restart restores messages and draft',
    () async {
      final bodies = <Map>[];
      final storage = MemoryChats();
      final models = TestModels();
      final api = ChatApi(
        clientFactory: () => MockClient((r) async {
          bodies.add(jsonDecode(r.body) as Map);
          return http.Response(
            sse([
              {
                'choices': [
                  {
                    'delta': {'content': '真实网络层回复'},
                    'finish_reason': 'stop',
                  },
                ],
              },
              {
                'choices': [],
                'usage': {'prompt_tokens': 20, 'completion_tokens': 5},
              },
              '[DONE]',
            ]),
            200,
            headers: {'content-type': 'text/event-stream; charset=utf-8'},
          );
        }),
      );
      final store = DemoStore(api: api, settings: models, storage: storage);
      await store.restore();
      expect(store.send('第一轮'), isTrue);
      expect(store.send('重复点击'), isFalse);
      await waitForReply(store);
      expect(store.messages.last.text, '真实网络层回复');
      expect(store.messages.last.status, 'complete');
      expect(store.messages.last.tokens, 5);
      store.send('第二轮');
      await waitForReply(store);
      expect(
        (bodies.last['messages'] as List)
            .where((m) => m['role'] == 'user')
            .length,
        2,
      );
      expect(jsonEncode(bodies.last), contains('真实网络层回复'));
      store.saveDraft(store.conversations.first, '尚未发送');
      await store.saveChats();
      store.dispose();
      final restored = DemoStore(api: api, settings: models, storage: storage);
      await restored.restore();
      expect(restored.messages.length, 4);
      expect(restored.conversations.first.draft, '尚未发送');
      expect(restored.conversations.first.usedTokens, 50);
      expect(storage.data, isNot(contains('test-key-only')));
      restored.dispose();
      models.dispose();
    },
  );

  test(
    'failed request retries the same user turn without adding duplicate messages',
    () async {
      var calls = 0;
      final store = DemoStore(
        settings: TestModels(),
        storage: MemoryChats(),
        api: ChatApi(
          clientFactory: () => MockClient((r) async {
            calls++;
            return calls == 1
                ? http.Response('invalid key', 401)
                : http.Response(
                    jsonEncode({
                      'choices': [
                        {
                          'message': {'content': '重试成功'},
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
      store.send('同一个问题');
      await waitForReply(store);
      expect(store.messages.last.status, 'failed');
      expect(store.messages.last.error, contains('鉴权失败'));
      store.regenerate();
      await waitForReply(store);
      expect(store.messages.length, 2);
      expect(store.messages.last.text, '重试成功');
      await store.saveChats();
      store.dispose();
    },
  );

  test(
    'stop while credential read is pending prevents any late network request',
    () async {
      var calls = 0;
      final models = TestModels()..pendingKey = Completer<String>();
      final store = DemoStore(
        settings: models,
        storage: MemoryChats(),
        api: ChatApi(
          clientFactory: () {
            calls++;
            return MockClient((r) async => http.Response('{}', 200));
          },
        ),
      );
      await store.restore();
      store.send('等待中的请求');
      final old = store.conversations.first;
      store.newChat();
      models.pendingKey!.complete('test-key-only');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(calls, 0);
      expect(old.messages.last.status, 'cancelled');
      expect(store.messages, isEmpty);
      await store.saveChats();
      store.dispose();
      models.dispose();
    },
  );

  test(
    'cancelled network stream cannot alter the newly selected conversation',
    () async {
      final controller = StreamController<List<int>>();
      final models = TestModels();
      final store = DemoStore(
        settings: models,
        storage: MemoryChats(),
        api: ChatApi(
          clientFactory: () => MockClient.streaming(
            (r, b) async => http.StreamedResponse(controller.stream, 200),
          ),
        ),
      );
      await store.restore();
      store.send('流式请求');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      controller.add(
        utf8.encode(
          sse([
            {
              'choices': [
                {
                  'delta': {'content': '已有内容'},
                },
              ],
            },
          ]),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final old = store.conversations.first;
      expect(old.messages.last.text, '已有内容');
      store.newChat();
      controller.add(
        utf8.encode(
          sse([
            {
              'choices': [
                {
                  'delta': {'content': '晚到内容'},
                },
              ],
            },
            '[DONE]',
          ]),
        ),
      );
      await controller.close();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(store.messages, isEmpty);
      expect(old.messages.last.text, '已有内容');
      expect(old.messages.last.status, 'cancelled');
      await store.saveChats();
      store.dispose();
      models.dispose();
    },
  );

  test(
    'interrupted saved reply is recoverable and storage failure stays visible',
    () async {
      final storage = MemoryChats()
        ..data = jsonEncode({
          'schema': 'skivu-chats-v1',
          'conversations': [
            {
              'title': '记录',
              'messages': [
                {'user': true, 'text': '问题'},
                {'user': false, 'text': '部分回复', 'status': 'pending'},
              ],
            },
          ],
        });
      final store = DemoStore(settings: TestModels(), storage: storage);
      await store.restore();
      expect(store.messages.last.status, 'cancelled');
      expect(store.messages.last.text, '部分回复');
      storage.failing = true;
      await store.saveChats();
      expect(store.storageError, isNotNull);
      store.dispose();
    },
  );

  test('bad imports leave existing messages and archive intact', () async {
    final storage = MemoryChats();
    final store = DemoStore(settings: TestModels(), storage: storage);
    await store.restore();
    store.messages.add(Message(true, '保留的消息'));
    await store.saveChats();
    final old = storage.data;
    await expectLater(
      store.importChats('{"schema":"skivu-chats-v1","conversations":[{}]}'),
      throwsA(anything),
    );
    expect(store.messages.single.text, '保留的消息');
    expect(storage.data, old);
    store.dispose();
  });
}

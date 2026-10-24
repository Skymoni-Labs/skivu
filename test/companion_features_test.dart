import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ski/chat_api.dart';
import 'package:ski/model_connection.dart';
import 'package:ski/companion_library.dart';
import 'package:ski/state.dart';
import 'package:ski/ui_host_binding.dart';
import 'package:ski/ui_plugins.dart';
import 'chat_api_test.dart' show connection;
import 'real_chat_store_test.dart' show MemoryChats, TestModels, waitForReply;

const image =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jQmQAAAAASUVORK5CYII=';
http.Response reply() => http.Response(
  jsonEncode({
    'choices': [
      {
        'message': {'content': '统一回复'},
      },
    ],
  }),
  200,
  headers: {'content-type': 'application/json'},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'queued bubbles survive restart; one confirmation sends one ordered request and deletes as one round',
    () async {
      final disk = MemoryChats(), requests = <Map<String, dynamic>>[];
      final store = DemoStore(
        storage: disk,
        settings: TestModels(),
        api: ChatApi(
          clientFactory: () => MockClient((r) async {
            requests.add(jsonDecode(r.body));
            return reply();
          }),
        ),
      );
      await store.restore();
      store.newChat();
      final chat = store.conversations[store.conversation];
      chat.confirmBeforeReply = true;
      expect(store.send('第一句'), isTrue);
      expect(store.send('第二句', kind: 'voice', described: true), isTrue);
      expect(store.send('夕阳下的海岸', kind: 'photo', described: true), isTrue);
      expect(requests, isEmpty);
      expect(store.streaming, isFalse);
      expect(chat.queuedMessages, hasLength(3));
      await store.saveChats();
      final restored = DemoStore(storage: disk, settings: TestModels());
      await restored.restore();
      expect(
        restored.conversations[restored.conversation].confirmBeforeReply,
        isTrue,
      );
      expect(
        restored.conversations[restored.conversation].queuedMessages,
        hasLength(3),
      );
      expect(restored.messages[1].kind, 'voice');
      expect(restored.messages[2].kind, 'photo');
      expect(store.confirmPending(streamingOverride: false), isTrue);
      await waitForReply(store);
      expect(requests, hasLength(1));
      final contents = (requests.single['messages'] as List)
          .where((m) => m['role'] == 'user')
          .map((m) => m['content'] as String)
          .toList();
      expect(contents[0], '第一句');
      expect(contents[1], contains('用户描述的一条语音'));
      expect(contents[2], contains('用户描述的一张照片'));
      expect(chat.queuedMessages, isEmpty);
      expect(store.messages.map((m) => m.turnId).toSet(), hasLength(1));
      expect(store.deleteRound(chat.id, store.messages.last), isTrue);
      expect(store.messages, isEmpty);
      restored.dispose();
      store.dispose();
    },
  );
  test(
    'pending messages stay with their own conversation; stale presenter commands cannot submit another chat',
    () async {
      final store = DemoStore(storage: MemoryChats(), settings: TestModels());
      await store.restore();
      store.newChat();
      final a = store.conversations[store.conversation];
      a.confirmBeforeReply = true;
      store.send('只属于A');
      final host = UiHostBinding(store);
      store.newChat();
      final b = store.conversations[store.conversation];
      b.confirmBeforeReply = true;
      store.send('只属于B');
      expect(
        host.mutate({
          'protocol': 1,
          'command': 'confirmBatch',
          'chatId': a.id,
        }, mode: ChatUiMode.wechat),
        contains('切换'),
      );
      expect(a.queuedMessages.single.text, '只属于A');
      expect(b.queuedMessages.single.text, '只属于B');
      expect(store.streaming, isFalse);
      store.models.connections.clear();
      expect(store.confirmPending(), isFalse);
      expect(b.queuedMessages, hasLength(1));
      store.discardQueued();
      expect(a.queuedMessages, hasLength(1));
      expect(b.messages, isEmpty);
      store.dispose();
    },
  );
  test(
    'world references share edits, scene categories stay independent, and archives migrate legacy prose without losing it',
    () async {
      final store = DemoStore(storage: MemoryChats(), settings: TestModels());
      await store.restore();
      final a = store.personas[0], b = store.personas[1];
      final world = WorldSetting(
        id: 'world-1',
        name: '海岛',
        category: '奇幻',
        summary: '有两轮月亮',
        entries: [
          WorldEntry(
            id: 'rule-1',
            name: '潮汐',
            category: '自然规则',
            content: '每日三次涨潮',
          ),
          WorldEntry(
            id: 'scene-1',
            name: '港口',
            category: '日常',
            content: '白色灯塔',
            scene: true,
          ),
          WorldEntry(
            id: 'scene-2',
            name: '深海',
            category: '冒险',
            content: '蓝色海沟',
            scene: true,
          ),
        ],
      );
      store.worlds.add(world);
      a.worldId = world.id;
      a.sceneId = 'scene-1';
      b.worldId = world.id;
      b.sceneId = 'scene-2';
      expect(store.promptFor(a), contains('白色灯塔'));
      expect(store.promptFor(a), isNot(contains('蓝色海沟')));
      expect(store.promptFor(b), contains('蓝色海沟'));
      world.summary = '有三轮月亮';
      expect(store.promptFor(a), contains('三轮'));
      expect(store.promptFor(b), contains('三轮'));
      final saved = store.exportChats();
      await store.importChats(saved);
      expect(store.worlds, hasLength(1));
      expect(store.personas[0].worldId, 'world-1');
      store.removeWorldEntry(store.worlds.single, 'scene-1');
      expect(store.personas[0].sceneId, isNull);
      expect(store.personas[1].sceneId, 'scene-2');
      final old = jsonDecode(store.exportChats()) as Map<String, dynamic>;
      old.remove('worlds');
      (old['personas'][0] as Map)['worldId'] = null;
      (old['personas'][0]['card'] as Map)['场景与世界观'] = '旧设定不会丢失';
      await store.importChats(jsonEncode(old));
      expect(store.promptFor(store.personas[0]), contains('旧设定不会丢失'));
      expect(store.personas[0].card.containsKey('场景与世界观'), isFalse);
      final before = store.exportChats();
      final invalid = jsonDecode(before) as Map<String, dynamic>;
      invalid['worlds'] = [
        {
          'id': 'bad',
          'name': '坏数据',
          'summary': '',
          'category': '分类',
          'entries': List.generate(
            101,
            (i) => {
              'id': 'entry-$i',
              'name': '条目',
              'category': '规则',
              'content': '内容',
            },
          ),
        },
      ];
      await expectLater(
        store.importChats(jsonEncode(invalid)),
        throwsFormatException,
      );
      expect(store.exportChats(), before);
      store.dispose();
    },
  );
  test(
    'sticker groups and sent stickers remain portable when a library item is retired',
    () async {
      final disk = MemoryChats();
      final store = DemoStore(storage: disk, settings: TestModels());
      await store.restore();
      store.newChat();
      store.stickerGroups.add(StickerGroup('group-1', '开心'));
      store.stickers.add(
        StickerAsset(
          id: 'sticker-1',
          groupId: 'group-1',
          name: '笑脸',
          data: image,
        ),
      );
      store.saveLibrary();
      store.conversations[store.conversation].confirmBeforeReply = true;
      expect(store.send('笑脸', kind: 'sticker', stickerId: 'sticker-1'), isTrue);
      store.stickers.single.active = false;
      await store.saveChats();
      final restored = DemoStore(storage: disk, settings: TestModels());
      await restored.restore();
      expect(restored.stickerGroups.single.name, '开心');
      expect(
        restored.stickerFor(restored.messages.single.stickerId)?.data,
        image,
      );
      final host = UiHostBinding(restored);
      final view = host.snapshot(ChatUiMode.qq, force: true);
      expect((view['messages'] as List).single['kind'], 'sticker');
      expect((view['stickers'] as List).single['active'], isFalse);
      expect(
        host.mutate({
          'protocol': 1,
          'command': 'sendSticker',
          'chatId': host.selected.id,
          'stickerId': 'sticker-1',
        }, mode: ChatUiMode.qq),
        contains('移除'),
      );
      expect(restored.messages.single.modelText, '[用户发送表情包：笑脸]');
      restored.dispose();
      store.dispose();
    },
  );
  for (final protocol in ApiProtocol.values) {
    test(
      '$protocol sends real image bytes in the provider format and keeps ordinary text as text',
      () async {
        Map<String, dynamic>? body;
        final api = ChatApi(
          clientFactory: () => MockClient((r) async {
            body = jsonDecode(r.body);
            return http.Response(
              jsonEncode({
                'choices': [
                  {
                    'message': {'content': 'ok'},
                  },
                ],
                'output_text': 'ok',
                'output': [
                  {
                    'type': 'message',
                    'content': [
                      {'type': 'output_text', 'text': 'ok'},
                    ],
                  },
                ],
                'content': [
                  {'type': 'text', 'text': 'ok'},
                ],
                'candidates': [
                  {
                    'content': {
                      'parts': [
                        {'text': 'ok'},
                      ],
                    },
                  },
                ],
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }),
        );
        final events = await api
            .start(connection(protocol, streaming: false), 'test-key-only', [
              {'role': 'user', 'content': '看这张照片', 'image': image},
            ], '')
            .events
            .toList();
        expect(events.any((e) => e.text == 'ok'), isTrue);
        switch (protocol) {
          case ApiProtocol.chat:
            expect(
              body!['messages'][0]['content'][1]['image_url']['url'],
              image,
            );
          case ApiProtocol.responses:
            expect(body!['input'][0]['content'][1]['image_url'], image);
          case ApiProtocol.anthropic:
            expect(
              body!['messages'][0]['content'][1]['source']['media_type'],
              'image/png',
            );
          case ApiProtocol.gemini:
            expect(
              body!['contents'][0]['parts'][1]['inlineData']['mimeType'],
              'image/png',
            );
        }
        expect(jsonEncode(body), isNot(contains('test-key-only')));
      },
    );
  }
}

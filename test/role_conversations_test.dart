import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ski/chat_api.dart';
import 'package:ski/state.dart';
import 'chat_api_test.dart' show sse;
import 'real_chat_store_test.dart' show MemoryChats, TestModels, waitForReply;

void main() {
  test(
    'deleting a role keeps other chats and restores valid ownership',
    () async {
      final disk = MemoryChats();
      final store = DemoStore(storage: disk);
      await store.restore();
      final a = store.personas[0], b = store.personas[1];
      store.newChat(personaId: a.id);
      final kept = store.conversations.first;
      kept.messages.add(Message(true, 'keep this context'));
      store.newChat(personaId: b.id);
      store.conversations.first.messages.add(Message(true, 'remove with role'));
      expect(store.removePersona(b.id), isTrue);
      expect(store.role.id, a.id);
      expect(store.conversations[store.conversation], same(kept));
      expect(kept.messages.single.text, 'keep this context');
      await store.saveChats();
      final restored = DemoStore(storage: disk);
      await restored.restore();
      expect(restored.personas.any((p) => p.id == b.id), isFalse);
      expect(restored.conversations.any((c) => c.personaId == b.id), isFalse);
      expect(restored.role.id, a.id);
      for (final p in restored.personas.toList().skip(1))
        restored.removePersona(p.id);
      expect(restored.removePersona(restored.personas.single.id), isFalse);
      expect(restored.role.id, restored.personas.single.id);
      store.dispose();
      restored.dispose();
    },
  );
  test(
    'group removal moves roles without deleting histories and persists',
    () async {
      final disk = MemoryChats();
      final store = DemoStore(storage: disk);
      await store.restore();
      expect(store.addGroup('  QA group  '), isTrue);
      expect(store.addGroup('QA group'), isFalse);
      final role = store.personas.first;
      role.group = 'QA group';
      store.newChat(personaId: role.id);
      final id = store.conversations.first.id;
      store.messages.add(Message(true, 'retained after group removal'));
      expect(store.deleteGroup('QA group'), isTrue);
      expect(role.group, '未分组');
      expect(store.groups, contains('未分组'));
      expect(store.deleteGroup('全部'), isFalse);
      expect(store.deleteGroup('未分组'), isFalse);
      await store.saveChats();
      final restored = DemoStore(storage: disk);
      await restored.restore();
      expect(restored.groups, isNot(contains('QA group')));
      expect(restored.personas.first.group, '未分组');
      expect(restored.conversations.first.id, id);
      expect(restored.messages.single.text, 'retained after group removal');
      store.dispose();
      restored.dispose();
    },
  );
  test(
    'same-role chats share current card but their requests, drafts and histories stay isolated',
    () async {
      final requests = <Map<String, dynamic>>[];
      final models = TestModels();
      final store = DemoStore(
        settings: models,
        storage: MemoryChats(),
        api: ChatApi(
          clientFactory: () => MockClient((r) async {
            requests.add(jsonDecode(r.body) as Map<String, dynamic>);
            return http.Response(
              sse([
                {
                  'choices': [
                    {
                      'delta': {'content': '完成'},
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
      final a = store.personas[0]
        ..name = 'ski'
        ..card = {'性格': '共享设定一'};
      final b = store.personas[1]
        ..name = '许知夏'
        ..prompt = '只属于角色B的提示';
      store.newChat(personaId: a.id);
      final first = store.conversations.first;
      store.send('仅第一段的问题');
      await waitForReply(store);
      store.saveDraft(first, '第一段草稿');
      store.newChat(personaId: a.id);
      final second = store.conversations.first;
      expect(second.messages, isEmpty);
      expect(second.draft, isEmpty);
      expect(second.usedTokens, 0);
      store.send('仅第二段的问题');
      await waitForReply(store);
      expect(jsonEncode(requests.last['messages']), isNot(contains('仅第一段的问题')));
      a.card['性格'] = '共享设定二';
      store.selectChat(store.conversations.indexOf(first));
      store.send('第一段继续');
      await waitForReply(store);
      final firstRequest = jsonEncode(requests.last['messages']);
      expect(firstRequest, contains('共享设定二'));
      expect(firstRequest, contains('仅第一段的问题'));
      expect(firstRequest, isNot(contains('仅第二段的问题')));
      expect(first.draft, '第一段草稿');
      store.newChat(personaId: b.id);
      store.persona =
          0; // Viewing/editing A's card must not change B's chat binding.
      store.send('角色B的问题');
      await waitForReply(store);
      expect(store.role.id, b.id);
      expect(jsonEncode(requests.last['messages']), contains('只属于角色B的提示'));
      expect(jsonEncode(requests.last['messages']), isNot(contains('共享设定二')));
      expect(store.conversationsFor(a.id), hasLength(2));
      expect(store.conversationsFor(b.id), hasLength(1));
      store.dispose();
      models.dispose();
    },
  );

  test(
    'role names, IDs, selected chat, pins, ownership and expansion survive restart and export import',
    () async {
      final disk = MemoryChats();
      final store = DemoStore(storage: disk);
      await store.restore();
      final a = store.personas[0], b = store.personas[1];
      store.newChat(personaId: a.id);
      final older = store.conversations.first;
      store.renameChat(older.id, '日常闲聊');
      store.saveDraft(older, 'draft-one');
      store.newChat(personaId: a.id);
      final newer = store.conversations.first;
      store.renameChat(newer.id, '一起做计划');
      store.toggleChatPin(older.id);
      expect(store.conversationsFor(a.id).first, older);
      expect(store.conversations[store.conversation], newer);
      a.name = '修改后的角色名';
      store.toggleFolder(a.id);
      store.newChat(personaId: b.id);
      store.renameChat(store.conversations.first.id, '另一角色的记录');
      store.selectChat(store.conversations.indexOf(older));
      store.toggleFolder(
        a.id,
      ); // Keep the selected folder collapsed across restart.
      await store.saveChats();
      final restored = DemoStore(storage: disk);
      await restored.restore();
      expect(restored.conversations[restored.conversation].id, older.id);
      expect(restored.role.id, a.id);
      expect(restored.role.name, '修改后的角色名');
      expect(restored.folderExpanded(a.id), isFalse);
      expect(restored.conversationsFor(a.id).first.pinned, isTrue);
      expect(restored.messages, isEmpty);
      expect(restored.conversations[restored.conversation].draft, 'draft-one');
      final imported = DemoStore(storage: MemoryChats());
      await imported.restore();
      await imported.importChats(restored.exportChats());
      expect(imported.role.id, a.id);
      expect(imported.folderExpanded(a.id), isFalse);
      expect(imported.conversationsFor(b.id).single.title, '另一角色的记录');
      store.dispose();
      restored.dispose();
      imported.dispose();
    },
  );

  test(
    'legacy archive gains ownership without dropping messages, roles, drafts or current selection',
    () async {
      final seed = DemoStore();
      final oldRoles = [
        for (final p in seed.personas) p.toJson()..remove('id'),
      ];
      final disk = MemoryChats()
        ..data = jsonEncode({
          'schema': 'skivu-chats-v1',
          'selected': 1,
          'persona': 1,
          'personas': oldRoles,
          'conversations': [
            {
              'title': '旧记录一',
              'messages': [
                {'user': true, 'text': '保留消息'},
              ],
              'draft': '保留草稿',
            },
            {'title': '旧记录二', 'messages': []},
          ],
        });
      final store = DemoStore(storage: disk);
      await store.restore();
      expect(store.conversations[store.conversation].title, '旧记录二');
      expect(store.conversations.first.messages.single.text, '保留消息');
      expect(store.conversations.first.draft, '保留草稿');
      expect(store.personas, hasLength(oldRoles.length));
      expect(
        store.conversations.every((c) => c.personaId == store.personas[1].id),
        isTrue,
      );
      await store.saveChats();
      final again = DemoStore(storage: disk);
      await again.restore();
      expect(
        again.conversations.map((c) => c.id),
        store.conversations.map((c) => c.id),
      );
      expect(again.role.id, store.role.id);
      expect(again.storageError, isNull);
      seed.dispose();
      store.dispose();
      again.dispose();
    },
  );

  test(
    'delete keeps a different selection stable and deleting last chat leaves an empty role folder',
    () async {
      final disk = MemoryChats();
      final store = DemoStore(storage: disk);
      await store.restore();
      final id = store.role.id;
      store.newChat();
      final first = store.conversations.first;
      store.newChat();
      final second = store.conversations.first;
      store.deleteChat(first.id);
      expect(store.conversations[store.conversation], second);
      store.deleteChat(second.id);
      expect(store.conversationsFor(id), isEmpty);
      expect(store.visibleConversations, isEmpty);
      expect(store.role.id, id);
      expect(store.messages, isEmpty);
      await store.saveChats();
      final again = DemoStore(storage: disk);
      await again.restore();
      expect(again.visibleConversations, isEmpty);
      again.newChat(personaId: id);
      expect(again.visibleConversations, hasLength(1));
      store.dispose();
      again.dispose();
    },
  );

  test(
    'manual title is retained on first send and invalid ownership imports preserve existing archive',
    () async {
      final models = TestModels(), disk = MemoryChats();
      final store = DemoStore(
        settings: models,
        storage: disk,
        api: ChatApi(
          clientFactory: () => MockClient(
            (_) async => http.Response(
              sse([
                {
                  'choices': [
                    {
                      'delta': {'content': '好'},
                    },
                  ],
                },
                '[DONE]',
              ]),
              200,
              headers: {'content-type': 'text/event-stream'},
            ),
          ),
        ),
      );
      await store.restore();
      store.newChat();
      final chat = store.conversations.first;
      store.renameChat(chat.id, '自定义标题');
      store.send('不能覆盖手动标题');
      await waitForReply(store);
      expect(chat.title, '自定义标题');
      await store.saveChats();
      final before = disk.data;
      final invalid = jsonDecode(store.exportChats()) as Map<String, dynamic>;
      (invalid['conversations'] as List).first['personaId'] = 'missing-role';
      await expectLater(
        store.importChats(jsonEncode(invalid)),
        throwsFormatException,
      );
      expect(disk.data, before);
      expect(store.conversations.first.title, '自定义标题');
      store.dispose();
      models.dispose();
    },
  );
}

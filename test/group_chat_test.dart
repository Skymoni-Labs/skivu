import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ski/chat_api.dart';
import 'package:ski/state.dart';
import 'package:ski/ui_host_binding.dart';
import 'real_chat_store_test.dart' show MemoryChats, TestModels, waitForReply;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'group members reply with their own cards, shared group history and a capped number of calls',
    () async {
      final requests = <Map<String, dynamic>>[],
          disk = MemoryChats(),
          models = TestModels();
      final store = DemoStore(
        storage: disk,
        settings: models,
        api: ChatApi(
          clientFactory: () => MockClient((r) async {
            requests.add(jsonDecode(r.body));
            return http.Response(
              jsonEncode({
                'choices': [
                  {
                    'message': {'content': '成员回复 ${requests.length}'},
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
      store.newChat();
      store.messages.add(Message(true, 'PRIVATE_SINGLE_CHAT'));
      final original = store.conversations[store.conversation];
      final members = store.personas.take(2).toList();
      members[0].prompt = 'CARD_A';
      members[1].prompt = 'CARD_B';
      final binding = UiHostBinding(store);
      expect(
        binding.mutate({
          'protocol': 1,
          'command': 'createGroup',
          'members': members.map((p) => p.id).toList(),
          'title': '一起做计划',
          'kind': 'channel',
          'rule': 'automatic',
          'maxReplies': 2,
        }),
        isNull,
      );
      final group = binding.selected;
      expect(group.groupKind, 'channel');
      expect(
        store.send('GROUP_ONLY_QUESTION', streamingOverride: false),
        isTrue,
      );
      await waitForReply(store);
      expect(requests, hasLength(2));
      expect(requests.every((r) => r['stream'] == false), isTrue);
      expect(jsonEncode(requests.first), contains('CARD_A'));
      expect(jsonEncode(requests.last), contains('CARD_B'));
      expect(jsonEncode(requests), isNot(contains('PRIVATE_SINGLE_CHAT')));
      expect(
        group.messages.where((m) => !m.user).map((m) => m.authorId),
        members.map((p) => p.id),
      );
      expect(original.messages.single.text, 'PRIVATE_SINGLE_CHAT');
      expect(models.active!.streaming, isTrue);
      store.regenerate();
      await waitForReply(store);
      expect(requests, hasLength(3));
      expect(jsonEncode(requests.last), contains('CARD_B'));
      expect(jsonEncode(requests.last), isNot(contains('PRIVATE_SINGLE_CHAT')));
      expect(group.messages.last.authorId, members.last.id);
      expect(group.messages.where((m) => !m.user), hasLength(2));
      expect(requests.last['stream'], isFalse);
      await store.saveChats();
      final restored = DemoStore(storage: disk);
      await restored.restore();
      final saved = restored.conversations.firstWhere((c) => c.id == group.id);
      expect(saved.groupMembers, group.groupMembers);
      expect(saved.groupKind, 'channel');
      expect(saved.messages.last.authorId, members.last.id);
      store.dispose();
      restored.dispose();
    },
  );
  test(
    'automatic prioritizes mentions while roundRobin follows order; streaming is respected',
    () async {
      for (final rule in ['automatic', 'roundRobin']) {
        final requests = <Map<String, dynamic>>[];
        final store = DemoStore(
          storage: MemoryChats(),
          settings: TestModels(),
          api: ChatApi(
            clientFactory: () => MockClient((r) async {
              requests.add(jsonDecode(r.body));
              return http.Response(
                'data: {"choices":[{"delta":{"content":"first"},"finish_reason":null}]}\n\ndata: {"choices":[{"delta":{"content":" second"},"finish_reason":"stop"}]}\n\n',
                200,
                headers: {'content-type': 'text/event-stream'},
              );
            }),
          ),
        );
        await store.restore();
        final members = store.personas.take(2).toList();
        UiHostBinding(store).mutate({
          'protocol': 1,
          'command': 'createGroup',
          'members': members.map((p) => p.id).toList(),
          'title': 'test',
          'rule': rule,
          'maxReplies': 1,
        });
        store.send('@${members.last.name} 请回复');
        await waitForReply(store);
        expect(requests.single['stream'], true);
        expect(
          store.messages.last.authorId,
          rule == 'automatic' ? members.last.id : members.first.id,
        );
        expect(store.messages.last.text, 'first second');
        store.regenerate();
        await waitForReply(store);
        expect(requests.last['stream'], true);
        store.dispose();
      }
    },
  );
  test(
    'mention-only groups do not call a model without an addressed member; cancellation stops later members',
    () async {
      final pending = Completer<http.Response>(), started = Completer<void>();
      var calls = 0;
      final store = DemoStore(
        storage: MemoryChats(),
        settings: TestModels(),
        api: ChatApi(
          clientFactory: () => MockClient((r) {
            calls++;
            started.complete();
            return pending.future;
          }),
        ),
      );
      await store.restore();
      final members = store.personas.take(2).toList();
      final binding = UiHostBinding(store);
      binding.mutate({
        'protocol': 1,
        'command': 'createGroup',
        'members': members.map((p) => p.id).toList(),
        'title': '安静的群聊',
        'rule': 'mentions',
        'maxReplies': 2,
      });
      expect(store.send('没有指定角色'), isTrue);
      expect(calls, 0);
      expect(store.streaming, isFalse);
      store.send('@${members.first.name} @${members.last.name} 开始');
      await started.future;
      store.stop();
      pending.complete(
        http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': '迟到的回复'},
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(calls, 1);
      expect(store.streaming, isFalse);
      expect(store.messages.any((m) => m.text == '迟到的回复'), isFalse);
      store.dispose();
    },
  );
}

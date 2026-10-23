import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ski/chat_api.dart';
import 'package:ski/social_activity.dart';
import 'package:ski/social_settings.dart';
import 'package:ski/state.dart';
import 'chat_api_test.dart' show connection;
import 'package:ski/model_connection.dart';
import 'real_chat_store_test.dart' show MemoryChats, TestModels;

Future<void> settle(SocialActivity activity) async {
  for (var i = 0; i < 100 && activity.busy; i++)
    await Future<void>.delayed(const Duration(milliseconds: 2));
  expect(activity.busy, isFalse);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'all automation starts off; configuration survives restart safely',
    () async {
      final settings = SocialSettings();
      await settings.restore();
      expect(settings.value.wechatPosts, isFalse);
      expect(settings.value.wechatComments, isFalse);
      expect(settings.value.qqPosts, isFalse);
      expect(settings.value.qqComments, isFalse);
      await settings.save(
        const SocialConfig(
          wechatComments: true,
          roleIds: ['r'],
          groupRule: GroupReplyRule.mentions,
          groupMembers: ['r'],
          groupMaxReplies: 2,
        ),
      );
      final restored = SocialSettings();
      await restored.restore();
      expect(restored.value.wechatComments, isTrue);
      expect(restored.value.qqComments, isFalse);
      expect(restored.value.groupRule, GroupReplyRule.mentions);
      expect(restored.value.groupMembers, ['r']);
      final malformed = SocialConfig.fromJson({
        'qqPosts': 'true',
        'groupRule': 'unknown',
        'intervalMinutes': 31,
        'groupHistoryLimit': 7,
        'dailyLimit': 500,
      });
      expect(malformed.qqPosts, isFalse);
      expect(malformed.groupRule, GroupReplyRule.manual);
      expect(malformed.intervalMinutes, 180);
      expect(malformed.groupHistoryLimit, 20);
      expect(malformed.dailyLimit, 10);
      settings.dispose();
      restored.dispose();
    },
  );

  test(
    'foreground opt-in jobs obey channel, interval, daily budget and restart',
    () async {
      final settings = SocialSettings();
      var now = DateTime(2026, 10, 23, 10);
      final calls = <String>[];
      Future<ChatSession> start(String id, String prompt) async {
        calls.add(id);
        return ChatSession(
          MockClient(
            (r) async => http.Response(
              jsonEncode({
                'choices': [
                  {
                    'message': {'content': '今天的云很好看。'},
                  },
                ],
              }),
              200,
              headers: {'content-type': 'application/json'},
            ),
          ),
          connection(ApiProtocol.chat, streaming: false),
          'test',
          [],
          prompt,
        );
      }

      final activity = SocialActivity(
        settings: settings,
        startSession: start,
        roleIds: () => ['r'],
        now: () => now,
      );
      await activity.restore();
      activity.setForeground(true);
      now = now.add(const Duration(days: 1));
      await activity.pump();
      expect(calls, isEmpty);
      await settings.save(
        const SocialConfig(
          wechatPosts: true,
          roleIds: ['r'],
          intervalMinutes: 30,
          dailyLimit: 1,
        ),
      );
      await activity.pump();
      expect(calls, isEmpty);
      now = now.add(const Duration(minutes: 30));
      await activity.pump();
      expect(calls, ['r']);
      expect(activity.feed('wx').single['author'], 'r');
      expect(activity.feed('qq'), isEmpty);
      now = now.add(const Duration(hours: 3));
      await activity.pump();
      expect(calls, hasLength(1));
      final restored = SocialActivity(
        settings: settings,
        startSession: start,
        roleIds: () => ['r'],
        now: () => now,
      );
      await restored.restore();
      expect(restored.usedToday, 1);
      expect(restored.feed('wx'), hasLength(1));
      activity.setForeground(false);
      now = now.add(const Duration(days: 1));
      await activity.pump();
      expect(calls, hasLength(1));
      activity.dispose();
      restored.dispose();
      settings.dispose();
    },
  );

  test(
    'comments are explicit opt-in and cancelled output cannot be published',
    () async {
      final settings = SocialSettings();
      var requests = 0;
      final reply = Completer<http.Response>();
      ChatSession? pending;
      final activity = SocialActivity(
        settings: settings,
        roleIds: () => ['r'],
        startSession: (id, prompt) async {
          requests++;
          return pending = ChatSession(
            MockClient((r) => reply.future),
            connection(ApiProtocol.chat, streaming: false),
            'test',
            [],
            prompt,
          );
        },
      );
      await activity.restore();
      activity.setForeground(true);
      activity.publish('wx', '未开启时不会回复', []);
      await settle(activity);
      expect(requests, 0);
      await settings.save(
        const SocialConfig(wechatComments: true, roleIds: ['r']),
      );
      activity.publish('qq', 'QQ 未开启', []);
      await settle(activity);
      expect(requests, 0);
      activity.publish('wx', '已明确开启', []);
      for (var i = 0; i < 50 && requests == 0; i++)
        await Future<void>.delayed(const Duration(milliseconds: 2));
      expect(requests, 1);
      await settings.save(const SocialConfig(roleIds: ['r']));
      expect(pending!.cancelled, isTrue);
      reply.complete(
        http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': '迟到的回复'},
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        ),
      );
      await settle(activity);
      expect(jsonEncode(activity.feed('wx')), isNot(contains('迟到的回复')));
      activity.dispose();
      settings.dispose();
    },
  );

  test(
    'social requests use only the role card and feed, never single-chat context',
    () async {
      final requests = <Map<String, dynamic>>[];
      final models = TestModels();
      final store = DemoStore(
        storage: MemoryChats(),
        settings: models,
        api: ChatApi(
          clientFactory: () => MockClient((r) async {
            requests.add(jsonDecode(r.body) as Map<String, dynamic>);
            return http.Response(
              jsonEncode({
                'choices': [
                  {
                    'message': {'content': '角色评论'},
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
      store.messages.add(Message(true, 'PRIVATE_CHAT_HISTORY'));
      final role = store.personas.first..prompt = 'ROLE_CARD_ONLY';
      final before = store.exportChats();
      final selected = store.conversation;
      final session = await store.startSocialReply(role.id, '动态内容');
      final events = await session.events.toList();
      expect(events.map((e) => e.text).join(), '角色评论');
      expect(requests.single['stream'], isFalse);
      expect(requests.single['max_tokens'], lessThanOrEqualTo(512));
      expect(jsonEncode(requests), contains('ROLE_CARD_ONLY'));
      expect(jsonEncode(requests), isNot(contains('PRIVATE_CHAT_HISTORY')));
      expect(store.exportChats(), before);
      expect(store.conversation, selected);
      expect(models.active!.streaming, isTrue);
      session.cancel();
      store.dispose();
    },
  );

  for (final channel in ['wx', 'qq'])
    test(
      '$channel enabled comments bind to the triggering post and survive restore',
      () async {
        final settings = SocialSettings();
        await settings.save(
          SocialConfig(
            wechatComments: channel == 'wx',
            qqComments: channel == 'qq',
            roleIds: const ['r'],
          ),
        );
        final activity = SocialActivity(
          settings: settings,
          roleIds: () => ['r'],
          startSession: (id, prompt) async => ChatSession(
            MockClient(
              (r) async => http.Response(
                jsonEncode({
                  'choices': [
                    {
                      'message': {'content': '一起期待明天！'},
                    },
                  ],
                }),
                200,
                headers: {'content-type': 'application/json'},
              ),
            ),
            connection(ApiProtocol.chat, streaming: false),
            'test',
            [],
            prompt,
          ),
        );
        await activity.restore();
        activity.setForeground(true);
        activity.publish(channel, '今天做了一个小计划', []);
        await settle(activity);
        final post = activity.feed(channel).single;
        expect((post['comments'] as List).single, {
          'author': 'r',
          'text': '一起期待明天！',
        });
        final restored = SocialActivity(
          settings: settings,
          roleIds: () => ['r'],
          startSession: (id, prompt) =>
              throw StateError('restore must not call model'),
        );
        await restored.restore();
        expect(restored.feed(channel).single['comments'], post['comments']);
        final legacy = [
          {
            'id': 'local-1',
            'author': 'self',
            'text': '原本的动态',
            'images': [],
            'likes': ['self'],
            'comments': [
              {'name': '我', 'text': '旧评论'},
            ],
          },
        ];
        final other = channel == 'qq' ? 'wx' : 'qq';
        await restored.importPosts(other, legacy);
        await restored.importPosts(other, legacy);
        expect(restored.feed(other), hasLength(1));
        expect(
          (restored.feed(other).single['comments'] as List).single['text'],
          '旧评论',
        );
        expect(restored.usedToday, 1);
        activity.dispose();
        restored.dispose();
        settings.dispose();
      },
    );
}

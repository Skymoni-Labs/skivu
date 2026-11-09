import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ski/assistant_engine.dart';
import 'package:ski/chat_api.dart';
import 'package:ski/cloud_conversations.dart';
import 'package:ski/cloud_execution_disclosure.dart';
import 'package:ski/device_engine.dart';
import 'package:ski/state.dart';
import 'package:ski/personal_space.dart';
import 'real_chat_store_test.dart' show MemoryChats, TestModels, waitForReply;

CloudChatCoordinator bind(
  DemoStore store,
  AssistantModel model, {
  Future<Map<String, dynamic>> Function(Map<String, dynamic>)? invoke,
}) {
  final coordinator = CloudChatCoordinator(
    store,
    engineFactory: (chat) => AssistantEngine(
      identity: () => 'qa-model',
      model: model,
      toolSubmissions: chat.toolSubmissions,
      engine: DeviceEngine(
        transport: (method, args) async => method == 'status'
            ? {'enabled': true, 'system': true}
            : await invoke!(args),
      ),
      read: () async => chat.assistantJournal == null
          ? null
          : jsonEncode(chat.assistantJournal),
      write: (raw) async {
        chat.assistantJournal = jsonDecode(raw) as Map<String, dynamic>;
        await store.saveChats();
      },
    ),
  );
  coordinator.attach();
  return coordinator;
}

void main() {
  test(
    'queued messages preserve selected tasks for this turn without carrying them into a new topic',
    () async {
      final tasks = PersonalSpaceStore(
        read: () async => null,
        write: (_) async {},
      );
      final first = await tasks.applyTask('create', {'title': '第一条'}, 'first');
      final second = await tasks.applyTask('create', {
        'title': '第二条',
      }, 'second');
      final histories = <String>[];
      final store = DemoStore(settings: TestModels(), storage: MemoryChats());
      await store.restore();
      final coordinator = CloudChatCoordinator(
        store,
        tasks: tasks,
        engineFactory: (chat) => AssistantEngine(
          identity: () => 'qa-model',
          read: () async => null,
          write: (_) async {},
          engine: DeviceEngine(
            transport: (method, args) async => {'enabled': false},
          ),
          model: (_, history) async {
            histories.add(history.last['content']!);
            return '{"type":"final","message":"收到"}';
          },
        ),
      );
      coordinator.attach();
      store.newChat(personaId: cloudPersonaId);
      store.conversations[store.conversation].confirmBeforeReply = true;
      expect(store.send('整理第一条', taskReference: first.id), true);
      expect(store.send('第二条也看一下', taskReference: second.id), true);
      expect(store.send('只查询状态'), true);
      expect(store.confirmPending(), true);
      await waitForReply(store);
      expect(histories.single, contains(first.id));
      expect(histories.single, contains(second.id));
      expect(histories.single, isNot(contains('"body"')));
      expect(store.send('换个话题', immediate: true), true);
      await waitForReply(store);
      expect(histories.last, isNot(contains('用户本条消息选中的任务')));
      store.dispose();
    },
  );
  test(
    'media reaches the shared transport and deleted rounds do not survive in task journals',
    () async {
      const image =
          'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAgAAAAQCAIAAACk6KkqAAAAFklEQVR4nGP0aV3FgA0wYRUdlaCxBABnigGboVweCAAAAABJRU5ErkJggg==';
      final histories = <List<Map<String, String>>>[];
      final disk = MemoryChats();
      final store = DemoStore(settings: TestModels(), storage: disk);
      await store.restore();
      bind(store, (_, history) async {
        histories.add(history);
        return '{"type":"final","message":"picture received"}';
      });
      store.newChat(personaId: cloudPersonaId);
      final chat = store.conversations.first;
      expect(
        store.send('private picture', kind: 'image', imageData: image),
        true,
      );
      await waitForReply(store);
      expect(histories.last.any((m) => m['image'] == image), true);
      expect(chat.assistantJournal, isNotNull);
      expect(store.deleteRound(chat.id, chat.messages.first), true);
      expect(chat.messages, isEmpty);
      expect(chat.assistantJournal, isNull);
      expect(store.send('new context'), true);
      await waitForReply(store);
      expect(jsonEncode(histories.last), isNot(contains('private picture')));
      expect(
        jsonEncode(chat.assistantJournal),
        isNot(contains('private picture')),
      );
      store.clearChatMessages(chat.id);
      await store.saveChats();
      final restored = DemoStore(storage: disk);
      await restored.restore();
      expect(restored.messages, isEmpty);
      expect(restored.conversations.first.assistantJournal, isNull);
      store.dispose();
      restored.dispose();
    },
  );
  test(
    'host role is unique, protected and normal names do not grant capabilities',
    () async {
      final disk = MemoryChats();
      final store = DemoStore(storage: disk);
      await store.restore();
      final normal = store.personas.first..name = '小云';
      expect(normal.isCloud, false);
      expect(store.removePersona(cloudPersonaId), false);
      store.addPersona(createCloudPersona());
      expect(store.personas.where((p) => p.isCloud), hasLength(1));
      final legacy = jsonDecode(store.exportChats()) as Map<String, dynamic>;
      (legacy['personas'] as List).removeWhere(
        (p) => p['id'] == cloudPersonaId,
      );
      await store.importChats(jsonEncode(legacy));
      expect(store.personas.where((p) => p.isCloud), hasLength(1));
      expect(store.role.id, normal.id);
      expect(store.personas.first.name, '小云');
      await store.importChats(store.exportChats());
      expect(store.personas.where((p) => p.isCloud), hasLength(1));
      store.dispose();
    },
  );

  test(
    'cloud chats share the composer data but isolate history, draft, quotes and transport',
    () async {
      final histories = <List<Map<String, String>>>[];
      var ordinary = 0;
      final disk = MemoryChats();
      final store = DemoStore(
        settings: TestModels(),
        storage: disk,
        api: ChatApi(
          clientFactory: () => MockClient((_) async {
            ordinary++;
            return http.Response(
              jsonEncode({
                'choices': [
                  {
                    'message': {'content': 'ordinary'},
                  },
                ],
              }),
              200,
            );
          }),
        ),
      );
      await store.restore();
      bind(store, (_, history) async {
        histories.add(history);
        return '{"type":"final","message":"cloud reply"}';
      });
      store.newChat(personaId: cloudPersonaId);
      final first = store.conversations.first;
      final source = Message(false, 'quoted context');
      first.messages.add(source);
      store.quoteMessage(first, source);
      expect(
        store.send('first cloud question', quotes: List.of(first.draftQuotes)),
        true,
      );
      await waitForReply(store);
      expect(first.messages.where((m) => m.user), hasLength(1));
      expect(first.draftQuotes, isEmpty);
      expect(jsonEncode(histories.last), contains('quoted context'));
      expect(first.messages.last.text, 'cloud reply');
      store.saveDraft(first, 'cloud draft');
      store.newChat(personaId: cloudPersonaId);
      final second = store.conversations.first;
      expect(store.send('second cloud question'), true);
      await waitForReply(store);
      expect(
        jsonEncode(histories.last),
        isNot(contains('first cloud question')),
      );
      expect(jsonEncode(histories.last), isNot(contains('quoted context')));
      expect(first.draft, 'cloud draft');
      store.newChat(personaId: store.personas.first.id);
      expect(store.send('normal question', streamingOverride: false), true);
      await waitForReply(store);
      expect(ordinary, 1);
      expect(histories, hasLength(2));
      await store.saveChats();
      final restored = DemoStore(storage: disk);
      await restored.restore();
      final saved = restored.conversations.firstWhere((c) => c.id == first.id);
      expect(saved.draft, 'cloud draft');
      expect(
        saved.messages.where((m) => m.user).single.quotes.single.text,
        source.text,
      );
      expect(
        restored.conversations
            .firstWhere((c) => c.id == second.id)
            .messages
            .last
            .text,
        'cloud reply',
      );
      store.dispose();
      restored.dispose();
    },
  );

  test(
    'permission journal resumes its own request after restart and retry cannot replay tools',
    () async {
      final disk = MemoryChats();
      var plans = 0, calls = 0, granted = false;
      final ids = <String>[];
      Future<Map<String, dynamic>> invoke(Map<String, dynamic> args) async {
        calls++;
        ids.add(args['requestId'] as String);
        return {
          'requestId': args['requestId'],
          'outcome': granted ? 'verified' : 'permission_required',
          'summary': 'brightness 80',
        };
      }

      Future<String> model(String _, List<Map<String, String>> __) async =>
          ++plans == 1 || plans == 3
          ? '{"type":"call","tool":"settings.brightness.read","arguments":{},"message":"read"}'
          : '{"type":"final","message":"brightness 80"}';
      final store = DemoStore(settings: TestModels(), storage: disk);
      await store.restore();
      final driver = bind(store, model, invoke: invoke);
      store.newChat(personaId: cloudPersonaId);
      final chat = store.conversations.first;
      store.send('read brightness');
      await waitForReply(store);
      expect(driver.canResume(chat.id), true);
      await store.saveChats();
      final restored = DemoStore(settings: TestModels(), storage: disk);
      await restored.restore();
      final next = bind(restored, model, invoke: invoke);
      final current = restored.conversations[restored.conversation];
      await next.restoreChat(current);
      expect(next.canResume(current.id), true);
      granted = true;
      restored.resumeCloud();
      await waitForReply(restored);
      expect(ids.length, 2);
      expect(ids.toSet(), hasLength(1));
      expect(current.messages.where((m) => m.toolReceipt), hasLength(3));
      final process = cloudTranscriptRows(
        current.messages,
        cloud: true,
      ).where((row) => row.execution).single;
      final step = cloudExecutionSteps(process.messages).single;
      expect(step.requestId, ids.first);
      expect(step.outcome, 'verified');
      expect(process.messages.every((m) => m.toolExecution != null), true);
      expect(current.messages.last.text, 'brightness 80');
      restored.regenerate();
      await waitForReply(restored);
      expect(
        calls,
        2,
        reason: 'Retry is a read-only review even if the model requests a tool',
      );
      expect(current.messages.last.text, contains('未继续执行'));
      store.dispose();
      restored.dispose();
    },
  );

  test(
    'stop immediately or during journal loading prevents a late model/tool dispatch',
    () async {
      var plans = 0;
      final store = DemoStore(settings: TestModels(), storage: MemoryChats());
      await store.restore();
      bind(store, (_, __) async {
        plans++;
        return '{"type":"final","message":"too late"}';
      });
      store.newChat(personaId: cloudPersonaId);
      store.send('cancel immediately');
      store.stop();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(plans, 0);
      final loading = Completer<String?>();
      final engine = AssistantEngine(
        model: (_, __) async {
          plans++;
          return '{"type":"final","message":"late"}';
        },
        identity: () => 'qa',
        read: () => loading.future,
        write: (_) async {},
      );
      final sending = engine.send('cancel loading');
      await engine.stop();
      loading.complete(null);
      await sending;
      expect(plans, 0);
      store.dispose();
    },
  );
}

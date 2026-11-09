import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ski/chat_api.dart';
import 'package:ski/model_connection.dart';
import 'package:ski/model_settings.dart';
import 'package:ski/relay_account.dart';
import 'package:ski/state.dart';
import 'package:ski/task_model_binding.dart';
import 'package:ski/assistant_reminder_tools.dart';
import 'package:ski/assistant_plan_tools.dart';
import 'package:ski/assistant_task_tools.dart';
import 'package:ski/personal_space.dart';
import 'package:ski/task_database.dart';
import 'package:ski/task_plans.dart';
import 'package:ski/task_scheduling_ui.dart';
import 'real_chat_store_test.dart' show MemoryChats;
import 'relay_account_test.dart' as account_test;

class SharedDocument implements TaskPersistence {
  int version = 0;
  String? value, backup;
  bool conflictOnce = false, fail = false;
  @override
  Future<TaskSnapshot> read() async => TaskSnapshot(version, value);
  @override
  Future<TaskSnapshot> initialize(String raw) async {
    if (value == null) {
      value = raw;
      backup = raw;
      version = 1;
    }
    return read();
  }

  @override
  Future<bool> compareAndSet(int expected, String raw) async {
    if (fail) throw StateError('disk');
    if (conflictOnce) {
      conflictOnce = false;
      version++;
      return false;
    }
    if (expected != version) return false;
    value = raw;
    version++;
    return true;
  }
}

void main() {
  test(
    'assistant respects the saved output limit and the explicit scheduled budget',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final models = ModelSettings();
      const config = ModelConnection(
        id: 'limit',
        name: 'limit',
        provider: 'test',
        protocol: ApiProtocol.chat,
        address: 'https://limits.example/v1',
        model: 'test',
        auth: 'none',
        streaming: false,
        maxOutput: 8192,
      );
      models.connections.add(config);
      models.activeId = config.id;
      final store = DemoStore(
        settings: models,
        storage: MemoryChats(),
        api: ChatApi(
          clientFactory: () => MockClient(
            (_) async => http.Response(
              jsonEncode({
                'choices': [
                  {
                    'message': {'content': 'ok'},
                  },
                ],
              }),
              200,
              headers: {'content-type': 'application/json'},
            ),
          ),
        ),
      );
      final foreground = await store.startAssistantReply('test', []);
      expect(foreground.config.maxOutput, 8192);
      await foreground.events.toList();
      final scheduled = await store.startAssistantReply(
        'test',
        [],
        maxOutputTokens: 512,
      );
      expect(scheduled.config.maxOutput, 512);
      await scheduled.events.toList();
      expect(models.active!.maxOutput, 8192);
      store.dispose();
      models.dispose();
    },
  );
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'a restored account loads current rights without overwriting foreground preferences',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      var revoked = false, invalid = false, modelCalls = 0;
      http.Client client() => MockClient((r) async {
        if (r.url.path.endsWith('/authorize'))
          return account_test.ok(account_test.authorization());
        if (r.url.path.endsWith('/token'))
          return account_test.ok(account_test.token());
        if (r.url.path.endsWith('/me'))
          return invalid
              ? account_test.failure('APP_SESSION_INVALID', 401)
              : account_test.ok(account_test.me());
        if (r.url.path.endsWith('/models'))
          return account_test.ok(
            revoked
                ? {'models': [], 'model_protocols': {}}
                : account_test.catalog(),
          );
        expect(r.url.path, '/api/app-account/chat/completions');
        expect(jsonDecode(r.body)['model'], 'chat-fixture');
        modelCalls++;
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': 'account pinned'},
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final original = RelayAccount(
        platform: account_test.AccountPlatform(),
        clientFactory: client,
      );
      await original.beginAuthorization();
      await original.pollAuthorization();
      final store = DemoStore(account: original, storage: MemoryChats())
        ..useAccount = true;
      final binding = scheduledModelBinding(store);
      await original.selectModel('responses-fixture');
      const secure = FlutterSecureStorage();
      final preferences = await secure.readAll();
      final restored = RelayAccount(
        platform: account_test.AccountPlatform(),
        clientFactory: client,
      );
      await restored.restore();
      expect(restored.user, isNull);
      await restored.refresh(persist: false);
      final background = DemoStore(account: restored, storage: MemoryChats())
        ..useAccount = true;
      final selected = resolveScheduledModel(background, binding);
      expect(selected?.model, 'chat-fixture');
      expect(restored.activeModel, 'responses-fixture');
      expect(await secure.readAll(), preferences);
      final session = await background.startAssistantReply(
        'test',
        [
          {'role': 'user', 'content': 'test'},
        ],
        requestConfig: selected,
        requestSource: 'account',
        streaming: false,
      );
      expect((await session.events.toList()).single.text, 'account pinned');
      expect(modelCalls, 1);
      revoked = true;
      await restored.refresh(persist: false);
      expect(resolveScheduledModel(background, binding), isNull);
      expect(await secure.readAll(), preferences);
      invalid = true;
      await restored.refresh(persist: false);
      expect(restored.signedIn, false);
      expect(await secure.readAll(), preferences);
      background.dispose();
      store.dispose();
      restored.dispose();
      original.dispose();
    },
  );
  test(
    'a saved model stays pinned and a changed credential requires rebinding',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final models = ModelSettings();
      const saved = ModelConnection(
        id: 'saved',
        name: 'saved',
        provider: 'test',
        protocol: ApiProtocol.chat,
        address: 'https://saved.example/v1',
        model: 'saved',
        auth: 'none',
        credentialId: 'first',
      );
      const other = ModelConnection(
        id: 'other',
        name: 'other',
        provider: 'test',
        protocol: ApiProtocol.chat,
        address: 'https://other.example/v1',
        model: 'other',
        auth: 'none',
      );
      models.connections.addAll([saved, other]);
      models.activeId = saved.id;
      var calls = 0;
      final store = DemoStore(
        settings: models,
        storage: MemoryChats(),
        api: ChatApi(
          clientFactory: () => MockClient((r) async {
            calls++;
            expect(r.url.host, 'saved.example');
            expect(jsonDecode(r.body)['model'], 'saved');
            return http.Response(
              jsonEncode({
                'choices': [
                  {
                    'message': {'content': 'pinned'},
                  },
                ],
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }),
        ),
      );
      final binding = scheduledModelBinding(store),
          identity = scheduledModelIdentity(store);
      models.activeId = other.id;
      store.useAccount = true;
      final resolved = resolveScheduledModel(store, binding);
      expect(resolved?.id, saved.id);
      final session = await store.startAssistantReply(
        'test',
        [
          {'role': 'user', 'content': 'test'},
        ],
        requestConfig: resolved,
        requestSource: binding['kind'],
        streaming: false,
      );
      expect((await session.events.toList()).single.text, 'pinned');
      expect(calls, 1);
      expect(modelBindingFingerprint(binding), identity);
      models.connections[0] = ModelConnection.fromJson({
        ...saved.toJson(),
        'credentialId': 'replacement',
      });
      expect(resolveScheduledModel(store, binding), isNull);
      store.dispose();
      models.dispose();
    },
  );
  test(
    'reminder filtering never joins unrelated records through an empty source',
    () async {
      final store = PersonalSpaceStore(
        read: () async => null,
        write: (_) async {},
      );
      final task = await store.applyTask('create', {'title': '本条任务'}, 'a');
      final database = TaskDatabase(
        transport: (method, args) async => switch (method) {
          'plans.list' => {'plans': []},
          'resources.list' => {
            'resources': [
              {'id': 'unrelated', 'taskId': 'other'},
              {'id': 'linked', 'taskId': task.id},
            ],
          },
          'runtime.pendingOpen' => {},
          _ => throw StateError(method),
        },
      );
      final plans = TaskPlans(database: database, supported: true);
      final tools = AssistantReminderTools(store, plans);
      final receipt = await tools.invoke(
        'tasks.reminder.list',
        {'taskId': task.id},
        'list',
        () {},
      );
      expect((receipt.data['value']['resources'] as List).map((r) => r['id']), [
        'linked',
      ]);
      await expectLater(
        tools.invoke(
          'tasks.reminder.list',
          {'taskId': 'missing'},
          'missing',
          () {},
        ),
        throwsFormatException,
      );
    },
  );
  test(
    'two engines share CAS storage, preserve both writes and reject stale editor versions',
    () async {
      final db = SharedDocument();
      PersonalSpaceStore open() =>
          PersonalSpaceStore(read: () async => null, persistence: db);
      final a = open(), b = open();
      await Future.wait([a.restore(), b.restore()]);
      await Future.wait([
        a.applyTask('create', {'title': '前台'}, 'a'),
        b.applyTask('create', {'title': '后台'}, 'b'),
      ]);
      await a.refresh();
      expect(a.tasks.map((r) => r.title).toSet(), {'前台', '后台'});
      final task = a.tasks.first;
      await b.applyTask('update', {
        'id': task.id,
        'expectedRevision': task.revision,
        'title': '后台新版本',
      }, 'b-update');
      await expectLater(
        a.save(
          memory: false,
          id: task.id,
          title: '过期编辑',
          expectedRevision: task.revision,
        ),
        throwsStateError,
      );
      await a.refresh();
      expect(a.task(task.id)!.title, '后台新版本');
    },
  );
  test(
    'a CAS retry is not a second business operation and failed commits publish nothing',
    () async {
      final db = SharedDocument();
      final store = PersonalSpaceStore(read: () async => null, persistence: db);
      await store.restore();
      db.conflictOnce = true;
      final record = await store.applyTask('create', {'title': '一次'}, 'one');
      expect(store.tasks, hasLength(1));
      final reopened = PersonalSpaceStore(
        read: () async => null,
        persistence: db,
      );
      expect(
        (await reopened.applyTask('create', {'title': '一次'}, 'one')).id,
        record.id,
      );
      db.fail = true;
      await expectLater(
        store.applyTask('create', {'title': '失败'}, 'fail'),
        throwsStateError,
      );
      expect(store.tasks, hasLength(1));
    },
  );
  test(
    'migration preserves memory, deadlines and a recovery snapshot without creating schedules',
    () async {
      final db = SharedDocument();
      final old = jsonEncode({
        'version': 1,
        'tasks': [
          PersonalRecord(
            id: 'dated',
            title: '旧安排',
            body: '',
            created: 1,
            updated: 1,
            date: '2025-01-01',
            time: '09:00',
          ).toJson(),
        ],
        'memories': [
          PersonalRecord(
            id: 'memory',
            title: '记忆',
            body: '保留',
            created: 1,
            updated: 1,
          ).toJson(),
        ],
      });
      final store = PersonalSpaceStore(read: () async => old, persistence: db);
      await store.restore();
      expect(db.backup, old);
      expect(store.memories.single.body, '保留');
      expect(store.tasks.single.time, '09:00');
      expect(jsonDecode(db.value!).containsKey('plans'), false);
    },
  );
  test(
    'working status is distinct from done and completion is still idempotent',
    () async {
      final store = PersonalSpaceStore(
        read: () async => null,
        write: (_) async {},
      );
      final r = await store.applyTask('create', {
        'title': '进行中',
        'inProgress': true,
      }, 'a');
      expect(r.inProgress, true);
      expect(r.done, false);
      final done = await store.applyTask('complete', {
        'id': r.id,
        'expectedRevision': r.revision,
        'done': true,
      }, 'done');
      expect(done.done, true);
      expect(done.inProgress, false);
    },
  );
  test(
    'plan tools bind the selected model, expose real schedules and never turn a task date into a plan',
    () async {
      final calls = <String>[];
      final records = <Map<String, dynamic>>[];
      final database = TaskDatabase(
        transport: (method, args) async {
          calls.add(method);
          if (method == 'plans.list') return {'plans': records};
          if (method == 'resources.list') return {'resources': []};
          if (method == 'runtime.pendingOpen') return {};
          if (method == 'plans.create') {
            final p = Map<String, dynamic>.from(args['arguments']);
            records.add({
              ...p,
              'id': 'plan_1',
              'version': 1,
              'state': 'enabled',
              'nextAt': p['rule']['at'],
            });
            return records.last;
          }
          throw StateError(method);
        },
      );
      final plans = TaskPlans(database: database, supported: true);
      final store = PersonalSpaceStore(
        read: () async => null,
        write: (_) async {},
      );
      final tools = AssistantPlanTools(
        AssistantTaskTools(store),
        plans,
        modelIdentity: () => List.filled(64, 'a').join(),
        modelName: () => '所选模型',
      );
      await tools.invoke(
        'tasks.create',
        {'title': '安排', 'date': '2026-11-10', 'time': '09:00'},
        'task',
        () {},
      );
      expect(calls, isEmpty);
      final result = await tools.invoke(
        'tasks.plan.create',
        {
          'taskId': store.tasks.single.id,
          'goal': '整理待办',
          'mode': 'summary',
          'rule': {'kind': 'once', 'at': 2000000000000},
        },
        'plan',
        () {},
      );
      expect(result.verified, true);
      expect(records.single['modelName'], '所选模型');
      expect(records.single['modelIdentity'], List.filled(64, 'a').join());
      expect(plans.records.single.state, 'enabled');
      await expectLater(
        tools.invoke(
          'tasks.plan.create',
          {
            'taskId': store.tasks.single.id,
            'goal': '不可用字段',
            'rule': {'kind': 'once', 'command': 'inject'},
          },
          'bad',
          () {},
        ),
        throwsFormatException,
      );
    },
  );
  testWidgets(
    'narrow plan editor accepts user budgets above old caps and allows zero',
    (tester) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final store = PersonalSpaceStore(
        read: () async => null,
        write: (_) async {},
      );
      final task = await store.applyTask('create', {'title': '测试计划'}, 'a');
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showTaskPlanEditor(
                  context,
                  task,
                  plans: TaskPlans(supported: true),
                ),
                child: const Text('打开计划'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开计划'));
      await tester.pumpAndSettle();
      Finder input(String label) => find.widgetWithText(TextFormField, label);
      for (final entry in {
        '本次模型请求预算（0不限制）': '125',
        '每日模型请求预算（0不限制）': '0',
        '输出 tokens（0沿用模型配置）': '262144',
      }.entries) {
        await tester.ensureVisible(input(entry.key));
        await tester.pumpAndSettle();
        await tester.enterText(input(entry.key), entry.value);
        await tester.pump();
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'schedule view shows plan state and latest result without tool-history rows',
    (tester) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final store = PersonalSpaceStore(
        read: () async => null,
        write: (_) async {},
      );
      final task = await store.applyTask('create', {'title': '每日整理'}, 'a');
      final plans = TaskPlans(supported: true)
        ..records = [
          TaskPlan({
            'id': 'plan_1',
            'taskId': task.id,
            'version': 1,
            'goal': '整理',
            'state': 'enabled',
            'rule': {'kind': 'daily', 'time': '21:00'},
            'nextAt': 2000000000000,
            'lastRun': {
              'state': 'verified',
              'dueAt': 1999990000000,
              'result': '未完成任务还有两项。',
              'summary': '完成',
            },
          }),
        ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: TaskSchedulesPane(
                store: store,
                plans: plans,
                openTask: (_) {},
              ),
            ),
          ),
        ),
      );
      expect(find.textContaining('已启用'), findsOneWidget);
      expect(find.text('未完成任务还有两项。'), findsOneWidget);
      expect(find.textContaining('工具历史'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

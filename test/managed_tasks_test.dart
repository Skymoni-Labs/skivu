import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ski/assistant_engine.dart';
import 'package:ski/assistant_task_tools.dart';
import 'package:ski/device_engine.dart';
import 'package:ski/personal_space.dart';
import 'package:ski/personal_space_ui.dart';
import 'package:ski/state.dart';
import 'package:ski/task_result_card.dart';
import 'package:ski/tool_execution.dart';

class MemoryTasks {
  String? raw;
  bool fail = false;
  int writes = 0;
  PersonalSpaceStore open() => PersonalSpaceStore(
    read: () async => raw,
    write: (v) async {
      if (fail) throw StateError('disk full');
      writes++;
      raw = v;
    },
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'v1 dates remain metadata, memories survive, original snapshot is backed up',
    () async {
      final old = jsonEncode({
        'version': 1,
        'tasks': [
          PersonalRecord(
            id: 'old',
            title: '过去的安排',
            body: '',
            date: '2026-01-01',
            time: '08:00',
            created: 1,
            updated: 1,
          ).toJson()..remove('revision'),
        ],
        'memories': [
          PersonalRecord(
            id: 'memory',
            title: '习惯',
            body: '喜欢安静',
            created: 1,
            updated: 1,
          ).toJson()..remove('revision'),
        ],
      });
      SharedPreferences.setMockInitialValues({personalSpaceKey: old});
      final store = PersonalSpaceStore();
      await store.restore();
      expect(store.tasks.single.revision, 1);
      expect(store.tasks.single.time, '08:00');
      await store.applyTask('create', {'title': '新增待办'}, 'new');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(personalSpaceBackupKey), old);
      final raw = jsonDecode(prefs.getString(personalSpaceKey)!) as Map;
      expect(raw['version'], 2);
      expect(raw.containsKey('schedules'), false);
      final reopened = PersonalSpaceStore();
      await reopened.restore();
      expect(reopened.memories.single.body, '喜欢安静');
      expect(reopened.tasks.first.toJson().containsKey('enabled'), false);
    },
  );

  test(
    'committed receipt survives restart; retries do not recreate or undo later edits',
    () async {
      final disk = MemoryTasks(), args = {'title': '写报告'};
      final first = await disk.open().applyTask('create', args, 'create');
      final store = disk.open();
      final retry = await store.applyTask('create', args, 'create');
      expect(retry.id, first.id);
      await store.applyTask('complete', {
        'id': first.id,
        'expectedRevision': 1,
        'done': true,
      }, 'done');
      final again = await disk.open().applyTask('create', args, 'create');
      expect(again.done, true);
      expect(disk.writes, 2);
      await expectLater(
        store.applyTask('create', {'title': '换了内容'}, 'create'),
        throwsStateError,
      );
      expect(store.tasks, hasLength(1));
    },
  );

  test(
    'failed persistence publishes no task or success receipt; explicit retry works',
    () async {
      final disk = MemoryTasks()..fail = true;
      final store = disk.open();
      await expectLater(
        store.applyTask('create', {'title': '失败后重试'}, 'one'),
        throwsStateError,
      );
      expect(store.tasks, isEmpty);
      expect(disk.raw, isNull);
      disk.fail = false;
      await store.applyTask('create', {'title': '失败后重试'}, 'one');
      expect(store.tasks, hasLength(1));
    },
  );

  test(
    'concurrent writes serialize and stale versions cannot overwrite a manual edit',
    () async {
      final disk = MemoryTasks(), store = disk.open();
      final rows = await Future.wait([
        store.applyTask('create', {'title': 'A'}, 'a'),
        store.applyTask('create', {'title': 'B'}, 'b'),
      ]);
      await store.save(
        memory: false,
        id: rows.first.id,
        title: '手动修改',
        expectedRevision: 1,
      );
      await expectLater(
        store.applyTask('update', {
          'id': rows.first.id,
          'expectedRevision': 1,
          'title': '旧模型的修改',
        }, 'stale'),
        throwsStateError,
      );
      expect(store.task(rows.first.id)!.title, '手动修改');
      expect(store.tasks, hasLength(2));
    },
  );

  test(
    'complete is an explicit assignment; retry never toggles back',
    () async {
      final disk = MemoryTasks(), store = disk.open();
      final task = await store.applyTask('create', {'title': '跑步'}, 'a');
      final args = {'id': task.id, 'expectedRevision': 1, 'done': true};
      await store.applyTask('complete', args, 'done1');
      await store.applyTask('complete', args, 'done2');
      expect(store.tasks.single.done, true);
      expect(store.tasks.single.revision, 2);
      await store.applyTask('complete', {
        'id': task.id,
        'expectedRevision': 2,
        'done': false,
      }, 'reopen');
      await store.applyTask('complete', args, 'done1');
      expect(store.tasks.single.done, false);
      await expectLater(
        store.applyTask('complete', args, 'old'),
        throwsStateError,
      );
    },
  );

  test(
    'cancelled queued edit cannot write after another edit commits',
    () async {
      final gate = Completer<void>(), started = Completer<void>();
      String? data;
      var cancelled = false, writes = 0;
      final store = PersonalSpaceStore(
        read: () async => null,
        write: (v) async {
          writes++;
          if (writes == 1) {
            started.complete();
            await gate.future;
          }
          data = v;
        },
      );
      final first = store.applyTask('create', {'title': '先保存'}, 'first');
      await started.future;
      final second = store.applyTask(
        'create',
        {'title': '应取消'},
        'cancelled',
        check: () {
          if (cancelled) throw StateError('stopped');
        },
      );
      final rejected = expectLater(second, throwsStateError);
      cancelled = true;
      gate.complete();
      await first;
      await rejected;
      expect(writes, 1);
      expect((jsonDecode(data!)['tasks'] as List).single['title'], '先保存');
    },
  );

  test(
    'task tools read bounded summaries, get full content and reject invented parameters',
    () async {
      final disk = MemoryTasks(),
          store = disk.open(),
          tools = AssistantTaskTools(store);
      final body = List.filled(300, '中').join();
      final r = await tools.invoke(
        'tasks.create',
        {'title': '报告', 'body': body, 'date': '2026-11-10', 'time': '08:00'},
        'create',
        () {},
      );
      expect(r.verified, true);
      final id = (r.data['value'] as Map)['id'];
      final page = await tools.invoke(
        'tasks.list',
        {'query': '报告', 'limit': 1},
        'read',
        () {},
      );
      expect((page.data['value'] as Map)['reminderEnabled'], false);
      expect(
        ((page.data['value'] as Map)['tasks'] as List).single['body'].length,
        lessThan(body.length),
      );
      final full = await tools.invoke('tasks.get', {'id': id}, 'get', () {});
      expect((full.data['value'] as Map)['body'], body);
      await expectLater(
        tools.invoke(
          'tasks.create',
          {'title': '坏参数', 'enabled': true},
          'bad',
          () {},
        ),
        throwsFormatException,
      );
      await expectLater(
        tools.invoke('tasks.list', {'limit': 51}, 'bad2', () {}),
        throwsFormatException,
      );
      expect(store.tasks, hasLength(1));
      final missing = await tools.invoke(
        'tasks.update',
        {'id': 'invented', 'expectedRevision': 1, 'title': '伪造'},
        'missing',
        () {},
      );
      expect(missing.outcome, 'failed');
    },
  );

  test(
    'cloud task edits execute locally with phone capabilities disabled and produce a linked card',
    () async {
      final disk = MemoryTasks(), store = disk.open();
      var round = 0, external = 0;
      final engine = AssistantEngine(
        identity: () => 'test',
        read: () async => null,
        write: (_) async {},
        taskTools: AssistantTaskTools(store),
        engine: DeviceEngine(
          transport: (method, args) async {
            if (method == 'status') return {'enabled': false};
            external++;
            throw StateError('must not invoke native task or effect lookup');
          },
        ),
        findPreviousEffect: (_, __) async =>
            throw StateError('no native lookup'),
        model: (system, history) async {
          expect(system, contains('普通回答不自动加入任务'));
          if (++round == 1)
            return jsonEncode({
              'type': 'call',
              'tool': 'tasks.create',
              'arguments': {'title': '明天交报告', 'date': '2026-11-10'},
              'message': '记录待办',
            });
          expect(history.last['content'], contains('本地任务记录已保存'));
          return '{"type":"final","message":"待办已保存，没有开启提醒。"}';
        },
      );
      await engine.send('记一下明天交报告');
      expect(engine.phase, 'done');
      expect(external, 0);
      expect(engine.toolSubmissions, isEmpty);
      final messages = [
        for (final m in engine.messages.where((m) => m['outcome'] != null))
          Message(false, m['content']!)
            ..toolReceipt = true
            ..toolExecution = ToolExecutionEvent.parse(m),
      ];
      final result = TaskResult.fromMessages(messages, phase: engine.phase)!;
      expect(result.managedTaskId, store.tasks.single.id);
      await store.save(
        memory: false,
        id: store.tasks.single.id,
        title: '手动改标题',
      );
      expect(result.displayTask(result.linkedTask(store)).title, '手动改标题');
      expect(result.displayTask(result.linkedTask(store)).status, '待办已保存');
    },
  );

  test('ordinary chat and temporary device reads never create a task', () async {
    final store = MemoryTasks().open();
    var round = 0;
    final engine = AssistantEngine(
      identity: () => 'test',
      read: () async => null,
      write: (_) async {},
      taskTools: AssistantTaskTools(store),
      engine: DeviceEngine(
        transport: (method, args) async => method == 'status'
            ? {'enabled': true}
            : {
                'requestId': args['requestId'],
                'outcome': 'verified',
                'value': {'level': 80},
              },
      ),
      model: (_, __) async => ++round == 1
          ? '{"type":"call","tool":"settings.brightness.read","arguments":{},"message":"看一下亮度"}'
          : '{"type":"final","message":"亮度80"}',
    );
    await engine.send('看一下亮度');
    expect(store.tasks, isEmpty);
  });

  test(
    'adding a system result only saves one completed record even after archive and restart',
    () async {
      final disk = MemoryTasks(), store = disk.open();
      final result = TaskResult.fromMessages([
        Message(false, '回执')
          ..toolReceipt = true
          ..toolExecution = const ToolExecutionEvent(
            taskId: 'cloud_1',
            requestId: 'cloud_1_1',
            tool: 'clock.alarm.create',
            purpose: '闹钟',
            outcome: 'verified',
            effect: 'write',
            resultTitle: '起床',
            resultDetail: '08:00 · 手机时钟',
            resultTarget: 'clock.alarms',
          ),
      ])!;
      final saved = await result.addToTasks(store);
      await result.addToTasks(store);
      expect(store.tasks, hasLength(1));
      expect(saved.done, true);
      expect(saved.sourceTarget, 'clock.alarms');
      expect(saved.date, '');
      await store.archive(saved.id, memory: false);
      final reopened = disk.open();
      final again = await result.addToTasks(reopened);
      expect(again.id, saved.id);
      expect(again.archived, true);
      expect(reopened.tasks, isEmpty);
      expect(reopened.archivedTasks, hasLength(1));
    },
  );

  test('task bindings persist and malformed references are ignored', () {
    final message = Message(true, '改到明天')..taskReference = 'task_123';
    expect(Message.fromJson(message.toJson()).taskReference, 'task_123');
    expect(
      Message.fromJson(
        message.toJson()..['taskReference'] = '../bad',
      ).taskReference,
      isNull,
    );
    final chat = Conversation('小云', [message])..draftTaskId = 'task_123';
    expect(Conversation.fromJson(chat.toJson()).draftTaskId, 'task_123');
  });

  testWidgets(
    'stale editor stays open and cannot overwrite a change made by cloud',
    (tester) async {
      final store = MemoryTasks().open();
      final task = await store.applyTask('create', {
        'title': '原来的标题',
      }, 'create');
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () =>
                    editPersonalRecord(context, store: store, record: task),
                child: const Text('编辑'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('编辑'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '手动旧版本');
      await store.applyTask('update', {
        'id': task.id,
        'expectedRevision': 1,
        'title': '小云的新版本',
      }, 'cloud');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(store.tasks.single.title, '小云的新版本');
      expect(find.text('任务已在其他位置修改，请重新打开。'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

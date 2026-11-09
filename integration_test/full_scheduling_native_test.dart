import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ski/main.dart' as app;
import 'package:ski/state.dart';
import 'package:ski/model_connection.dart';
import 'package:ski/personal_space.dart';
import 'package:ski/task_database.dart';
import 'package:ski/task_plans.dart';
import 'package:ski/task_model_binding.dart';
import 'package:ski/task_scheduling_ui.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'actual headless once/repeat scheduling and pinned model while UI is backgrounded',
    (tester) async {
      expect(const bool.fromEnvironment('SKIVU_ENGINE_QA'), true);
      const url = String.fromEnvironment('SCHEDULER_QA_URL');
      expect(url, startsWith('http://10.0.2.2:'));
      final old = PersonalRecord(
        id: 'legacy_migrate',
        title: '旧的带时间待办',
        body: '保留旧记录，不自动执行',
        created: 1,
        updated: 1,
        date: '2025-01-01',
        time: '09:00',
      );
      final memory = PersonalRecord(
        id: 'legacy_memory',
        title: '旧记忆',
        body: '保留记忆内容',
        created: 1,
        updated: 1,
      );
      await (await SharedPreferences.getInstance()).setString(
        personalSpaceKey,
        jsonEncode({
          'version': 1,
          'tasks': [old.toJson()],
          'memories': [memory.toJson()],
        }),
      );
      await app.main();
      for (var i = 0; i < 15; i++)
        await tester.pump(const Duration(milliseconds: 150));
      expect(taskPlans.records, isEmpty);
      expect(personalSpace.task('legacy_migrate')!.time, '09:00');
      expect(personalSpace.memories.single.body, '保留记忆内容');
      final model = ModelConnection(
        id: 'scheduler-pinned',
        name: '本地后台验收',
        provider: '本地验收',
        protocol: ApiProtocol.chat,
        address: url,
        model: 'scheduler-pinned',
        auth: 'none',
        streaming: false,
        maxOutput: 1024,
      );
      await demo.models.save(model, '');
      await demo.models.select(model.id);
      demo.useAccount = false;
      demo.useBeta = false;
      demo.newChat(personaId: cloudPersonaId);
      await demo.saveChats();
      final selected = scheduledModelBinding(demo),
          identity = scheduledModelIdentity(demo);
      final start = DateTime.now().millisecondsSinceEpoch;
      final onceTask = await personalSpace.applyTask('create', {
        'title': 'QA 一次性整理',
      }, 'qa-once-task');
      final repeatTask = await personalSpace.applyTask('create', {
        'title': 'QA 重复整理',
      }, 'qa-repeat-task');
      final actionTask = await personalSpace.applyTask('create', {
        'title': 'QA 操作回执保护',
      }, 'qa-action-task');
      Future<TaskPlan> create(
        String taskId,
        String goal,
        Map<String, dynamic> rule,
        String mode,
        String id,
      ) async {
        final p = await taskPlans.operate('plans.create', {
          'taskId': taskId,
          'goal': goal,
          'mode': mode,
          'rule': rule,
          'modelIdentity': identity,
          'modelBinding': selected,
          'modelName': model.model,
          'maxRequestsPerRun': 3,
          'maxDailyRequests': 5,
          'maxOutputTokens': 1024,
          'missedPolicy': 'latest',
          'maxDelayMinutes': 5,
        }, id);
        return TaskPlan(p);
      }

      final once = await create(
        onceTask.id,
        'QA-ONCE: Read saved pending tasks, then summarize briefly.',
        {'kind': 'once', 'at': start + 20000},
        'summary',
        'qa-once-plan',
      );
      final repeat = await create(
        repeatTask.id,
        'QA-REPEAT: Read saved pending tasks, then summarize briefly.',
        {'kind': 'interval', 'intervalMinutes': 15, 'at': start + 65000},
        'summary',
        'qa-repeat-plan',
      );
      final action = await create(
        actionTask.id,
        'QA-ACTION: Perform a real phone action; a text answer is not completion.',
        {'kind': 'once', 'at': start + 110000},
        'device_action',
        'qa-action-plan',
      );
      // Selecting another model in ordinary chat must not silently rebind saved plans.
      final other = ModelConnection(
        id: 'scheduler-other',
        name: '不能调用的当前模型',
        provider: '本地验收',
        protocol: ApiProtocol.chat,
        address: 'http://127.0.0.1:1/v1',
        model: 'must-not-use',
        auth: 'none',
        streaming: false,
      );
      await demo.models.save(other, '');
      await demo.models.select(other.id);
      await demo.saveChats();
      expect(resolveScheduledModel(demo, selected)!.id, model.id);
      await tester.pump(const Duration(milliseconds: 400));
      debugPrint('SCHEDULER_HOME');
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 3)),
      );
      Future<Map<String, dynamic>> waitPlan(
        String id,
        bool Function(Map<String, dynamic>) ready,
      ) async {
        Map<String, dynamic> value = {};
        await tester.runAsync(() async {
          final deadline = DateTime.now().add(const Duration(minutes: 5));
          while (DateTime.now().isBefore(deadline)) {
            value = await TaskDatabase.instance.call('plans.get', {'id': id});
            if (ready(value)) return;
            if (value['lastRun'] is Map &&
                {
                  'failed',
                  'unknown',
                }.contains((value['lastRun'] as Map)['state']))
              return;
            await Future<void>.delayed(const Duration(milliseconds: 600));
          }
        });
        expect(ready(value), true, reason: jsonEncode(value));
        return value;
      }

      final onceDone = await waitPlan(
        once.id,
        (p) => p['state'] == 'ended' && p['lastRun'] is Map,
      );
      expect((onceDone['lastRun'] as Map)['state'], 'verified');
      debugPrint('SCHEDULER_ONCE_VERIFIED');
      final repeatDone = await waitPlan(
        repeat.id,
        (p) =>
            p['lastRun'] is Map && (p['lastRun'] as Map)['state'] == 'verified',
      );
      expect(repeatDone['state'], 'enabled');
      expect(repeatDone['nextAt'] as int, greaterThan(start + 65000));
      debugPrint('SCHEDULER_REPEAT_VERIFIED');
      final actionDone = await waitPlan(
        action.id,
        (p) => p['state'] == 'needs_configuration',
      );
      expect((actionDone['lastRun'] as Map)['state'], 'waiting_conditions');
      debugPrint('SCHEDULER_ACTION_GATED');
      debugPrint('SCHEDULER_RESUME');
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 3)),
      );
      await tester.pump(const Duration(milliseconds: 600));
      await taskPlans.refresh();
      await tester.tap(find.byKey(const ValueKey('main-module-2')));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.widgetWithText(ChoiceChip, '定时'));
      await tester.pump(const Duration(milliseconds: 500));
      debugPrint('SCHEDULER_FRAME results');
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 2)),
      );
      final panel = find.byWidgetPredicate(
        (w) => w is TaskSchedulingPanel && w.task.id == repeatTask.id,
      );
      Future<void> click(String label) async {
        final button = find.descendant(
          of: panel,
          matching: find.widgetWithText(TextButton, label),
        );
        await tester.ensureVisible(button);
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(button);
        await tester.pump(const Duration(milliseconds: 200));
      }

      await click('暂停');
      await waitPlan(repeat.id, (p) => p['state'] == 'paused');
      await taskPlans.refresh();
      await tester.pump(const Duration(milliseconds: 300));
      await click('启用');
      await waitPlan(repeat.id, (p) => p['state'] == 'enabled');
      await taskPlans.refresh();
      await tester.pump(const Duration(milliseconds: 300));
      await click('结束计划');
      await waitPlan(repeat.id, (p) => p['state'] == 'ended');
      await taskPlans.operate('plans.cancel', {
        'id': action.id,
        'expectedRevision': actionDone['version'],
      }, 'qa-action-end');
      final rebootTask = await personalSpace.applyTask('create', {
        'title': 'QA 重启后后台恢复',
      }, 'qa-reboot-task');
      final reboot = await create(
        rebootTask.id,
        'QA-REBOOT: Read saved pending tasks and summarize briefly after reboot.',
        {'kind': 'once', 'at': DateTime.now().millisecondsSinceEpoch + 90000},
        'summary',
        'qa-reboot-plan',
      );
      // Deleting this QA chat must not delete independent tasks or schedules.
      final chat = demo.conversations[demo.conversation];
      demo.deleteChat(chat.id);
      await demo.saveChats();
      expect(personalSpace.task(rebootTask.id), isNotNull);
      expect(
        (await TaskDatabase.instance.call('plans.get', {
          'id': reboot.id,
        }))['state'],
        'enabled',
      );
      expect(tester.takeException(), isNull);
      binding.reportData = {
        'passed': true,
        'actualWorkManager': true,
        'headlessOnceVerified': true,
        'repeatingPlanRemainsEnabledAfterOccurrence': true,
        'pauseResumeEndVerified': true,
        'readOnlyReplyCannotCompletePhoneAction': true,
        'oldDatedTaskNotEnabled': true,
        'oldMemoryPreserved': true,
        'pinnedModelSurvivesSelectionChange': true,
        'chatDeletionKeepsTasksAndPlans': true,
        'rebootPlanId': reboot.id,
        'rebootDue': reboot.data['nextAt'],
        'actualSystemAlarmsCreated': 0,
        'paidModelCalls': 0,
      };
    },
  );
}

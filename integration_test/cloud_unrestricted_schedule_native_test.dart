import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ski/main.dart' as app;
import 'package:ski/state.dart';
import 'package:ski/model_connection.dart';
import 'package:ski/cloud_coding_tools.dart';
import 'package:ski/task_plans.dart';
import 'package:ski/task_model_binding.dart';
import 'package:ski/personal_space.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'renewed background occurrence crosses three minutes and five model requests',
    (tester) async {
      expect(const bool.fromEnvironment('SKIVU_ENGINE_QA'), true);
      const url = String.fromEnvironment('CODING_SCHEDULE_QA_URL');
      expect(url, startsWith('http://10.0.2.2:'));
      await app.main();
      await taskPlans.refresh();
      for (final old
          in taskPlans.records
              .where(
                (p) => p.data['modelName'] == '本地受控定时编程' && p.state != 'ended',
              )
              .toList()) {
        if (old.lastRun?['id'] is String)
          await taskPlans.database.call('runs.stop', {
            'id': old.lastRun!['id'],
          });
        await taskPlans.operate('plans.cancel', {
          'id': old.id,
          'expectedRevision': old.revision,
        }, 'qa_clean_${DateTime.now().microsecondsSinceEpoch}');
      }
      for (var i = 0; i < 15; i++)
        await tester.pump(const Duration(milliseconds: 180));
      final setup = await cloudExecutionChannel
          .invokeMapMethod<String, dynamic>('invoke', {
            'tool': 'coding.projects.create',
            'arguments': {'name': 'QA 真实后台编程'},
            'owner': 'cloud:schedule_setup',
            'taskId': 'schedule_setup',
            'requestId': 'setup_${DateTime.now().microsecondsSinceEpoch}',
          });
      expect(setup?['outcome'], 'verified');
      final project = (setup!['value'] as Map)['id'];
      final model = ModelConnection(
        id: 'unrestricted-schedule-model',
        name: '本地受控定时编程',
        provider: '本地验收',
        protocol: ApiProtocol.chat,
        address: url,
        model: 'unrestricted-schedule',
        auth: 'none',
        streaming: false,
        maxOutput: 0,
      );
      await demo.models.save(model, '');
      await demo.models.select(model.id);
      demo.useAccount = false;
      demo.useBeta = false;
      final task = await personalSpace.applyTask(
        'create',
        {'title': 'QA 后台编程成果'},
        'unrestricted-schedule-task-${DateTime.now().microsecondsSinceEpoch}',
      );
      final p = await taskPlans.operate(
        'plans.create',
        {
          'taskId': task.id,
          'goal':
              '[UNRESTRICTED_SCHEDULE $project] 运行一个持续200秒的真实内置程序，在完成后检查结果、搜索、补充说明，只交付最终 scheduled-long.txt。',
          'mode': 'coding',
          'projectId': project,
          'rule': {
            'kind': 'once',
            'at': DateTime.now().millisecondsSinceEpoch + 12000,
          },
          'modelIdentity': scheduledModelIdentity(demo),
          'modelBinding': scheduledModelBinding(demo),
          'modelName': model.name,
          'maxRequestsPerRun': 0,
          'maxDailyRequests': 0,
          'maxOutputTokens': 0,
        },
        'unrestricted-schedule-plan-${DateTime.now().microsecondsSinceEpoch}',
      );
      debugPrint('CODING_SCHEDULE_READY ${p['id']}');
      Map<String, dynamic>? last;
      for (var i = 0; i < 2400; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 150)),
        );
        await tester.pump(const Duration(milliseconds: 50));
        await taskPlans.refresh();
        last = taskPlans.records.singleWhere((r) => r.id == p['id']).lastRun;
        if (last != null && last['state'] != 'running') break;
      }
      expect(last?['state'], 'verified');
      expect(last?['requests'], 8);
      final record = await taskPlans.database.call('runs.get', {
        'id': last!['id'],
      });
      expect(
        (record['heartbeatAt'] as num) - (record['started'] as num),
        greaterThanOrEqualTo(180000),
      );
      expect(
        (last['finished'] as num) - (record['started'] as num),
        greaterThanOrEqualTo(200000),
      );
      expect(last['artifactIds'], hasLength(1));
      final rows = await cloudExecutionChannel.invokeListMethod<dynamic>(
        'artifacts',
        {'owner': 'cloud:${p['id']}'},
      );
      expect(rows, hasLength(1));
      expect((rows!.single as Map)['name'], 'scheduled-long.txt');
      final preview = await cloudExecutionChannel
          .invokeMapMethod<String, dynamic>('artifact.preview', {
            'id': (rows.single as Map)['id'],
          });
      expect(preview?['text'], 'LEASE_RENEWED\n');
      final ended = taskPlans.records.singleWhere((r) => r.id == p['id']);
      expect(ended.state, 'ended');
      await taskPlans.refresh();
      expect(
        taskPlans.records.singleWhere((r) => r.id == p['id']).lastRun?['id'],
        last['id'],
      );
      binding.reportData = {
        'controlledModel': true,
        'realWorkManager': true,
        'naturalTrigger': true,
        'builtInCoding': true,
        'planId': p['id'],
        'runId': last['id'],
        'requests': last['requests'],
        'artifactCount': rows.length,
        'onceEnded': true,
        'heartbeatAt': record['heartbeatAt'],
        'startedAt': record['started'],
        'finishedAt': last['finished'],
        'activeMillis': record['activeMillis'],
        'unrestrictedRequests': true,
        'unrestrictedOutputParameter': true,
      };
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}

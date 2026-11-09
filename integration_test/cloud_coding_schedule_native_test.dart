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
    'natural background occurrence uses built-in project and final manifest',
    (tester) async {
      expect(const bool.fromEnvironment('SKIVU_ENGINE_QA'), true);
      const url = String.fromEnvironment('CODING_SCHEDULE_QA_URL');
      expect(url, startsWith('http://10.0.2.2:'));
      await app.main();
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
        id: 'coding-schedule-model',
        name: '本地受控定时编程',
        provider: '本地验收',
        protocol: ApiProtocol.chat,
        address: url,
        model: 'coding-schedule',
        auth: 'none',
        streaming: false,
        maxOutput: 1024,
      );
      await demo.models.save(model, '');
      await demo.models.select(model.id);
      demo.useAccount = false;
      demo.useBeta = false;
      final task = await personalSpace.applyTask('create', {
        'title': 'QA 后台编程成果',
      }, 'coding-schedule-task');
      final p = await taskPlans.operate('plans.create', {
        'taskId': task.id,
        'goal':
            '[SCHEDULE_CODE $project] 仅在绑定项目生成最终 schedule.txt，内容为 BUILTIN_BACKGROUND_OK；交付该文件。',
        'mode': 'coding',
        'projectId': project,
        'rule': {
          'kind': 'once',
          'at': DateTime.now().millisecondsSinceEpoch + 12000,
        },
        'modelIdentity': scheduledModelIdentity(demo),
        'modelBinding': scheduledModelBinding(demo),
        'modelName': model.name,
        'maxRequestsPerRun': 3,
        'maxDailyRequests': 3,
        'maxOutputTokens': 1024,
      }, 'coding-schedule-plan');
      debugPrint('CODING_SCHEDULE_READY ${p['id']}');
      Map<String, dynamic>? last;
      for (var i = 0; i < 1200; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 150)),
        );
        await tester.pump(const Duration(milliseconds: 50));
        await taskPlans.refresh();
        last = taskPlans.records.singleWhere((r) => r.id == p['id']).lastRun;
        if (last != null && last['state'] != 'running') break;
      }
      expect(last?['state'], 'verified');
      expect(last?['requests'], 3);
      expect(last?['artifactIds'], hasLength(1));
      final rows = await cloudExecutionChannel.invokeListMethod<dynamic>(
        'artifacts',
        {'owner': 'cloud:${p['id']}'},
      );
      expect(rows, hasLength(1));
      expect((rows!.single as Map)['name'], 'schedule.txt');
      final preview = await cloudExecutionChannel
          .invokeMapMethod<String, dynamic>('artifact.preview', {
            'id': (rows.single as Map)['id'],
          });
      expect(preview?['text'], 'BUILTIN_BACKGROUND_OK\n');
      final ended = taskPlans.records.singleWhere((r) => r.id == p['id']);
      expect(ended.state, 'ended');
      await taskPlans.refresh();
      expect(
        taskPlans.records.singleWhere((r) => r.id == p['id']).lastRun?['id'],
        last?['id'],
      );
      binding.reportData = {
        'controlledModel': true,
        'realWorkManager': true,
        'naturalTrigger': true,
        'builtInCoding': true,
        'planId': p['id'],
        'runId': last?['id'],
        'requests': last?['requests'],
        'artifactCount': rows.length,
        'onceEnded': true,
      };
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

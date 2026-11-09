import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ski/main.dart' as app;
import 'package:ski/state.dart';
import 'package:ski/model_connection.dart';
import 'package:ski/device_engine.dart';
import 'package:ski/task_plans.dart';
import 'package:ski/task_model_binding.dart';
import 'package:ski/personal_space.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    debugPrint('DEVICE_SCHEDULE_NEEDS_QA_ACCESSIBILITY');
    final device = DeviceEngine();
    var status = await device.status();
    for (var i = 0; i < 150 && status['accessibility'] != true; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      status = await device.status();
    }
    expect(status['accessibility'], true);
    await Future<void>.delayed(const Duration(milliseconds: 300));
  });
  testWidgets(
    'scheduled clock launch recovers from a failed observation and verifies original side effect',
    (tester) async {
      expect(const bool.fromEnvironment('SKIVU_ENGINE_QA'), true);
      const url = String.fromEnvironment('DEVICE_SCHEDULE_QA_URL');
      expect(url, startsWith('http://10.0.2.2:'));
      await app.main();
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 180));
      }
      final device = DeviceEngine();
      await device.configure(
        enabled: true,
        system: true,
        control: true,
        shell: false,
        packages: ['com.android.deskclock'],
        allApplications: false,
      );
      final status = await device.status();
      expect(status['accessibility'], true);
      final model = ModelConnection(
        id: 'device-schedule-recovery',
        name: '本地受控定时手机恢复',
        provider: '本地验收',
        protocol: ApiProtocol.chat,
        address: url,
        model: 'device-recovery',
        auth: 'none',
        streaming: false,
        maxOutput: 0,
      );
      await demo.models.save(model, '');
      await demo.models.select(model.id);
      demo.useAccount = false;
      demo.useBeta = false;
      final task = await personalSpace.applyTask('create', {
        'title': 'QA 定时打开时钟并核验',
      }, 'device-schedule-task-${DateTime.now().microsecondsSinceEpoch}');
      final plan = await taskPlans.operate(
        'plans.create',
        {
          'taskId': task.id,
          'goal':
              '[DEVICE_SCHEDULE_RECOVERY] 定时打开时钟，先观察当前界面，若当前界面不可观察则打开时钟后重新核验；最终确认已打开。',
          'mode': 'device_action',
          'rule': {
            'kind': 'once',
            'at': DateTime.now().millisecondsSinceEpoch + 12000,
          },
          'modelIdentity': scheduledModelIdentity(demo),
          'modelBinding': scheduledModelBinding(demo),
          'modelName': model.name,
          'allowForeground': true,
          'maxRequestsPerRun': 0,
          'maxDailyRequests': 0,
          'maxOutputTokens': 0,
        },
        'device-schedule-plan-${DateTime.now().microsecondsSinceEpoch}',
      );
      debugPrint('DEVICE_SCHEDULE_READY ${plan['id']}');
      Map<String, dynamic>? last;
      for (var i = 0; i < 1000; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 150)),
        );
        await tester.pump(const Duration(milliseconds: 50));
        await taskPlans.refresh();
        last = taskPlans.records.singleWhere((p) => p.id == plan['id']).lastRun;
        if (last != null &&
            !{
              'running',
              'waiting_conditions',
              'interrupted',
            }.contains(last['state']))
          break;
      }
      expect(last?['state'], 'verified');
      expect(last?['requests'], 4);
      final run = await taskPlans.database.call('runs.get', {
        'id': last!['id'],
      });
      final ended = taskPlans.records.singleWhere((p) => p.id == plan['id']);
      expect(ended.state, 'ended');
      await taskPlans.database.call('runtime.reconcile');
      await taskPlans.refresh();
      expect(
        taskPlans.records.singleWhere((p) => p.id == plan['id']).lastRun?['id'],
        last['id'],
      );
      binding.reportData = {
        'controlledModel': true,
        'actualWorkManager': true,
        'naturalTrigger': true,
        'appTarget': 'com.android.deskclock',
        'planId': plan['id'],
        'runId': last['id'],
        'state': last['state'],
        'requests': last['requests'],
        'onceEnded': true,
        'started': run['started'],
        'finished': last['finished'],
        'recoveredFromEarlierFailedObservation': true,
      };
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}

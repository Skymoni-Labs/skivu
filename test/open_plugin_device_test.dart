import 'package:flutter_test/flutter_test.dart';
import 'package:ski/device_task.dart';
import 'package:ski/open_plugin_device.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final disconnected in [false, true]) {
    test(
      'stop updates public state while planning is still pending (disconnected=$disconnected)',
      () async {
        final tasks = OpenPluginDeviceTasks();
        var revoked = 0;
        final runner = DeviceTaskRunner(
          id: 'pending',
          request: (method, args) async {
            if (method == 'end') revoked++;
            if (disconnected) throw StateError('companion disconnected');
            return {};
          },
          plan: (observation, receipts) async => throw StateError('unused'),
          update: (state, summary) async {},
          check: () {},
          waitForConfirmation: () async {},
          apps: {'test.notes'},
          maxActions: 3,
          maxRounds: 3,
          deadline: DateTime.now().add(const Duration(minutes: 1)),
        );
        runner.capability = 'test-lease';
        tasks.active = runner;
        tasks.tasks['pending'] = {
          'taskId': 'pending',
          'pluginId': 'not-installed',
          'digest': 'none',
          'state': 'planning',
          'actions': 1,
          'rounds': 0,
        };
        await tasks.cancel();
        expect(revoked, 1);
        expect(tasks.publicTask(tasks.tasks['pending']!)['state'], 'cancelled');
        expect(
          tasks.publicTask(tasks.tasks['pending']!)['errorCode'],
          'CANCELLED',
        );
        expect(
          runner.guard,
          throwsA(
            isA<DeviceTaskFailure>().having((e) => e.code, 'code', 'CANCELLED'),
          ),
        );
      },
    );
  }
}

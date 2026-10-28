import 'package:flutter_test/flutter_test.dart';
import 'package:ski/device_task.dart';
import 'package:ski/open_plugin_device.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:ski/open_plugin.dart';
import 'package:ski/open_plugin_network.dart';
import 'package:ski/state.dart';
import 'package:ski/model_connection.dart';
import 'package:ski/model_settings.dart';
import 'open_plugin_test.dart' as fixtures;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'direct permission skips repeat connection dialogs, reuses bindings and pins the signer',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'skivu-device-grants-',
      );
      PathProviderPlatform.instance = fixtures.TestPaths(temp.path);
      openPlugins.records.clear();
      await openPlugins.install(
        fixtures.package(
          permissions: [
            'device.observe',
            'device.control',
            'device.direct',
            'agent.tasks',
          ],
        ),
      );
      await openPlugins.setEnabled('test.free-plugin', true);
      final record = openPlugins.records['test.free-plugin']!;
      const channel = MethodChannel('skivu/device_tasks');
      var bindings = 0, popups = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'connect') {
              bindings++;
              return {'connectionId': 'own-binding', 'signerSha256': 'a' * 64};
            }
            if (call.method == 'request') {
              final request =
                  jsonDecode((call.arguments as Map)['json'] as String) as Map;
              expect(request['method'], anyOf('pair', 'hello'));
              return jsonEncode({
                'approved': true,
                'directControlApproved': true,
                'accessibilityEnabled': true,
              });
            }
            if (call.method == 'startService')
              throw PlatformException(code: 'NOTIFICATIONS_REQUIRED');
            return true;
          });
      addTearDown(() async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        openPlugins.records.clear();
        modelSettings.connections.clear();
        modelSettings.activeId = null;
        final resolved = temp.resolveSymbolicLinksSync();
        expect(
          resolved,
          startsWith(
            Directory.systemTemp.resolveSymbolicLinksSync() +
                Platform.pathSeparator,
          ),
        );
        await temp.delete(recursive: true);
      });
      final tasks = OpenPluginDeviceTasks();
      Future<bool> consent(String a, String b) async {
        popups++;
        return true;
      }

      final args = {
        'component': 'test.bridge/test.bridge.Service',
        'signerSha256': 'a' * 64,
      };
      await tasks.dispatch(record, 'device.connect', args, consent);
      await tasks.dispatch(record, 'device.connect', args, consent);
      expect(bindings, 1);
      expect(popups, 0);
      demo.useBeta = false;
      demo.useAccount = false;
      modelSettings.connections.add(
        const ModelConnection(
          id: 'fixture',
          name: 'Fixture',
          provider: 'Ollama',
          protocol: ApiProtocol.chat,
          address: 'http://127.0.0.1:9/v1',
          model: 'fixture',
          auth: 'none',
          streaming: false,
        ),
      );
      modelSettings.activeId = 'fixture';
      await expectLater(
        tasks.dispatch(record, 'agent.tasks.start', {
          'connectionId': 'own-binding',
          'goal': 'Local fixture only',
          'allowedPackages': ['test.notes'],
        }, consent),
        throwsA(
          isA<PluginApiError>().having(
            (error) => error.code,
            'code',
            'NOTIFICATIONS_REQUIRED',
          ),
        ),
      );
      expect(popups, 0);
      expect(tasks.active, isNull);
      expect(tasks.tasks, isEmpty);
      expect(await tasks.journal.restore(), isEmpty);
      await expectLater(
        tasks.dispatch(record, 'device.connect', {
          ...args,
          'signerSha256': 'b' * 64,
        }, consent),
        throwsA(
          isA<PluginApiError>().having(
            (error) => error.code,
            'code',
            'COMPANION_CHANGED',
          ),
        ),
      );
      await openPlugins.install(
        fixtures.package(
          id: 'test.other-plugin',
          permissions: ['device.observe', 'device.control'],
        ),
      );
      await openPlugins.setEnabled('test.other-plugin', true);
      await expectLater(
        tasks.dispatch(
          openPlugins.records['test.other-plugin']!,
          'device.status',
          {'connectionId': 'own-binding'},
          consent,
        ),
        throwsA(
          isA<PluginApiError>().having(
            (error) => error.code,
            'code',
            'PERMISSION_DENIED',
          ),
        ),
      );
    },
  );
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

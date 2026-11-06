import 'package:flutter_test/flutter_test.dart';
import 'package:ski/device_engine.dart';
import 'package:ski/device_tool_catalog.dart';
import 'package:ski/open_plugin_tools.dart';

void main() {
  test(
    'catalog contains unique valid schemas and distinguishes permissions',
    () {
      expect(
        builtinDeviceTools.map((tool) => tool.id).toSet().length,
        builtinDeviceTools.length,
      );
      for (final tool in builtinDeviceTools) {
        validatePluginSchema(tool.parameters);
        expect(tool.description, isNotEmpty);
        expect(tool.parameters['additionalProperties'], false);
      }
      expect(deviceTool('clock.alarm.create').permission, 'device.system');
      expect(deviceTool('shell.execute').permission, 'device.shell');
      expect(deviceTool('ui.observe').permission, 'device.observe');
    },
  );

  test('a dispatched clock intent is never reported as verified', () async {
    final engine = DeviceEngine(
      transport: (method, args) async => {
        'requestId': args['requestId'],
        'outcome': 'dispatched',
        'summary': '时钟请求已派发，需要核对。',
      },
    );
    final receipt = await engine.invoke(
      'clock.alarm.create',
      {'hour': 7, 'minute': 30},
      owner: 'assistant',
      requestId: 'alarm_1',
    );
    expect(receipt.verified, false);
    expect(receipt.outcome, 'dispatched');
  });

  test('arguments cannot inject host ownership or native actions', () async {
    var calls = 0;
    final engine = DeviceEngine(
      transport: (_, args) async {
        calls++;
        return {'requestId': args['requestId'], 'outcome': 'verified'};
      },
    );
    await expectLater(
      engine.invoke('clock.alarm.create', {
        'hour': 7,
        'minute': 30,
        'owner': 'system',
      }, owner: 'plugin.example'),
      throwsFormatException,
    );
    await expectLater(
      engine.invoke('ui.tap', {
        'observationId': 'screen_1',
        'elementId': 'n_1',
        'package': 'forged.app',
      }, owner: 'assistant'),
      throwsFormatException,
    );
    await expectLater(
      engine.invoke('unknown.native', {}, owner: 'assistant'),
      throwsFormatException,
    );
    expect(calls, 0);
  });

  test('reply identity and unknown outcomes fail closed', () async {
    final engine = DeviceEngine(
      transport: (_, args) async => {
        'requestId': 'different',
        'outcome': 'verified',
      },
    );
    await expectLater(
      engine.invoke('device.status', {}, owner: 'assistant'),
      throwsFormatException,
    );
    expect(
      () => DeviceToolReceipt({'requestId': '1', 'outcome': 'ok'}),
      throwsFormatException,
    );
    final receipt = DeviceToolReceipt({'requestId': '1', 'outcome': 'unknown'});
    expect(receipt.verified, false);
  });

  test(
    'shell tools stay unavailable without a real elevated connection',
    () async {
      final engine = DeviceEngine(
        transport: (_, args) async => {
          'enabled': true,
          'system': true,
          'control': true,
          'shell': true,
          'shellConnected': false,
          'accessibility': false,
        },
      );
      final catalog = await engine.catalog();
      expect(
        catalog.firstWhere((t) => t['id'] == 'shell.execute')['available'],
        false,
      );
      expect(
        catalog.firstWhere((t) => t['id'] == 'ui.tap')['available'],
        false,
      );
      expect(
        catalog.firstWhere((t) => t['id'] == 'clock.alarm.create')['available'],
        true,
      );
    },
  );
}

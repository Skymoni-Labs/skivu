import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ski/device_engine.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const enabled = bool.fromEnvironment('SKIVU_ENGINE_QA');
  final engine = DeviceEngine();
  final prefix = DateTime.now().microsecondsSinceEpoch.toString();

  testWidgets(
    'real native engine denies disabled use and reports actual state',
    (tester) async {
      expect(
        enabled,
        true,
        reason: 'This acceptance must use the isolated QA application ID.',
      );
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Text('Native engine acceptance')),
        ),
      );
      final state = await engine.configure(
        enabled: false,
        system: false,
        control: false,
        shell: false,
        packages: [],
      );
      expect(state['version'], 1);
      expect(state['enabled'], false);
      expect(state['shellConnected'], false);
      expect(state['shellUid'], null);
      final result = await engine.invoke(
        'clock.alarm.create',
        {'hour': 7, 'minute': 30},
        owner: 'qa',
        requestId: '${prefix}_disabled',
      );
      expect(result.outcome, 'permission_required');
    },
  );

  testWidgets(
    'real Android app discovery and brightness reads return actual data',
    (tester) async {
      await engine.configure(
        enabled: true,
        system: true,
        control: true,
        shell: false,
        packages: ['com.android.deskclock', 'com.android.settings'],
      );
      final apps = await engine.invoke('apps.list', {}, owner: 'qa');
      expect(apps.verified, true);
      final rows = apps.data['value'] as List;
      expect(rows, isNotEmpty);
      expect(
        rows.whereType<Map>().any(
          (row) => row['package'] == 'com.android.settings',
        ),
        true,
      );
      final brightness = await engine.invoke(
        'settings.brightness.read',
        {},
        owner: 'qa',
      );
      expect(brightness.verified, true);
      expect((brightness.data['value'] as Map)['level'], isA<int>());
    },
  );

  testWidgets('native validation refuses invalid clock values without dispatch', (
    tester,
  ) async {
    for (final hour in [-1, 24, 7.5]) {
      final result = await DeviceEngine.channel.invokeMapMethod<String, dynamic>(
        'invoke',
        {
          'version': 1,
          'owner': 'qa',
          'requestId':
              '${prefix}_bad_${hour.toString().replaceAll('.', '_').replaceAll('-', 'n')}',
          'tool': 'clock.alarm.create',
          'arguments': {'hour': hour, 'minute': 30},
        },
      );
      expect(result!['outcome'], 'failed');
    }
  });

  testWidgets('native request IDs cannot be reused for a different write', (
    tester,
  ) async {
    final request = '${prefix}_reused';
    final rejected = await engine.invoke(
      'clock.alarm.create',
      {'hour': 25, 'minute': 30},
      owner: 'qa',
      requestId: request,
    );
    expect(rejected.outcome, 'failed');
    await expectLater(
      engine.invoke(
        'clock.alarm.create',
        {'hour': 7, 'minute': 30},
        owner: 'qa',
        requestId: request,
      ),
      throwsA(isA<PlatformException>()),
    );
    final replay = await engine.invoke(
      'clock.alarm.create',
      {'hour': 25, 'minute': 30},
      owner: 'qa',
      requestId: request,
    );
    expect(replay.outcome, 'failed');
    await engine.configure(
      enabled: false,
      system: false,
      control: false,
      shell: false,
      packages: [],
    );
    final afterRevocation = await engine.invoke(
      'clock.alarm.create',
      {'hour': 25, 'minute': 30},
      owner: 'qa',
      requestId: request,
    );
    expect(afterRevocation.outcome, 'permission_required');
  });
}

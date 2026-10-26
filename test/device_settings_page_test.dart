import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/device_settings_page.dart';

void main() {
  const channel = MethodChannel('skivu/device_tasks');
  testWidgets(
    'device settings shows real companions and routes to plugin management without a demo pairing code',
    (tester) async {
      String? method, route;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'discover')
          return [
            {
              'component': 'test.bridge/test.bridge.Service',
              'label': 'Test companion',
            },
          ];
        method = call.method;
        return true;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: DeviceSettingsPage(go: (value) => route = value),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Test companion'), findsOneWidget);
      expect(find.text('设备配对演示'), findsNothing);
      await tester.tap(find.text('Test companion'));
      await tester.pumpAndSettle();
      expect(method, 'openCompanionSettings');
      await tester.tap(find.text('管理操控插件'));
      expect(route, '/open-plugins');
    },
  );
  testWidgets(
    'unsupported or missing device service gives an actionable state',
    (tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) async => throw PlatformException(
          code: 'ANDROID_VERSION_UNSUPPORTED',
          message: '手机操控需要 Android 11 或更新系统',
        ),
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: DeviceSettingsPage(go: (_) {})),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Android 11'), findsWidgets);
      expect(find.text('刷新设备伴侣'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

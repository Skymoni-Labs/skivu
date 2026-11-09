import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/device_engine.dart';
import 'package:ski/embedded_engine_settings.dart';

void main() {
  testWidgets(
    'pairing fields keep their state across native calls and show actual UID',
    (tester) async {
      var paired = false, connected = false;
      final calls = <String>[];
      tester.view.physicalSize = const Size(500, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        DeviceEngine.channel,
        (call) async {
          calls.add(call.method);
          if (call.method == 'apps') return [];
          if (call.method == 'adb.pair') {
            paired = true;
            return {'paired': true, 'summary': 'paired'};
          }
          if (call.method == 'adb.connect') {
            expect(paired, true);
            connected = true;
            return {'connected': true};
          }
          return {
            'enabled': true,
            'system': true,
            'control': false,
            'shell': true,
            'accessibility': false,
            'writeSettings': false,
            'packages': [],
            'shellConnected': connected,
            'shellUid': connected ? 2000 : null,
            'developerOptions': true,
          };
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          DeviceEngine.channel,
          null,
        ),
      );
      await tester.pumpWidget(
        const MaterialApp(home: EmbeddedEngineSettings()),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('UID 2000'), findsNothing);
      await tester.tap(find.text('代码执行 · 无线配对'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(0), '37001');
      await tester.enterText(find.byType(TextField).at(1), '123456');
      await tester.tap(find.text('完成系统配对'));
      await tester.pumpAndSettle();
      expect(paired, true);
      expect(find.text('无线调试连接端口'), findsOneWidget);
      await tester.enterText(find.byType(TextField).at(2), '38001');
      await tester.ensureVisible(find.text('连接并验证身份'));
      await tester.tap(find.text('连接并验证身份'));
      await tester.pumpAndSettle();
      expect(find.text('已连接 · UID 2000'), findsOneWidget);
      expect(calls, containsAllInOrder(['adb.pair', 'adb.connect', 'status']));
      expect(tester.takeException(), isNull);
    },
  );
}

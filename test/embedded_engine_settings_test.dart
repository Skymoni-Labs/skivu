import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/embedded_engine_settings.dart';

void main() {
  testWidgets(
    'native pairing retains fields and connects only after explicit confirmation',
    (tester) async {
      tester.view.physicalSize = const Size(500, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      const native = MethodChannel('dsh/phone');
      const events = MethodChannel('dsh/phone/events');
      final messenger = tester.binding.defaultBinaryMessenger;
      final calls = <MethodCall>[];
      var paired = false;
      var connected = false;
      messenger.setMockMethodCallHandler(events, (_) async => null);
      messenger.setMockMethodCallHandler(native, (call) async {
        calls.add(call);
        if (call.method == 'adbPair') {
          expect(call.arguments, {'code': '123456', 'port': 37001});
          paired = true;
          return true;
        }
        if (call.method == 'adbConnect') {
          expect(paired, true);
          connected = true;
          return true;
        }
        if (call.method == 'status')
          return {
            'background': {
              'privileged': {'mode': 'adb', 'ready': connected},
            },
          };
        return <String, dynamic>{};
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(native, null);
        messenger.setMockMethodCallHandler(events, null);
      });
      await tester.pumpWidget(
        const MaterialApp(home: EmbeddedEngineSettings()),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('无线配对与连接'), 300);
      await tester.tap(find.text('无线配对与连接'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('填写无线配对码'));
      await tester.tap(find.text('填写无线配对码'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(0), '123456');
      await tester.enterText(find.byType(TextField).at(1), '37001');
      await tester.pump();
      expect(find.text('123456'), findsOneWidget);
      expect(find.text('37001'), findsOneWidget);
      expect(paired, false);
      await tester.tap(find.widgetWithText(FilledButton, '配对'));
      await tester.pumpAndSettle();
      expect(paired, true);
      expect(connected, false);
      await tester.ensureVisible(find.text('连接无线调试'));
      await tester.tap(find.text('连接无线调试'));
      await tester.pumpAndSettle();
      expect(connected, true);
      expect(
        calls.map((e) => e.method),
        containsAllInOrder(['adbPair', 'status', 'adbConnect', 'status']),
      );
      expect(tester.takeException(), isNull);
    },
  );
}

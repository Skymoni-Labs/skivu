import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/device_tool_catalog.dart';
import 'package:ski/embedded_engine_settings.dart';

void main() {
  const native = MethodChannel('dsh/phone');
  const events = MethodChannel('dsh/phone/events');
  Future<void> mount(
    WidgetTester tester, {
    double scale = 1,
    Size size = const Size(500, 1800),
    required Future<dynamic> Function(MethodCall) handler,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(native, handler);
    messenger.setMockMethodCallHandler(events, (_) async => null);
    addTearDown(() {
      messenger.setMockMethodCallHandler(native, null);
      messenger.setMockMethodCallHandler(events, null);
    });
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(
            size: size,
            textScaler: TextScaler.linear(scale),
          ),
          child: const EmbeddedEngineSettings(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'native screen inspection requires an explicit action and loading settings does not capture',
    (tester) async {
      final calls = <String>[];
      await mount(
        tester,
        handler: (call) async {
          calls.add(call.method);
          if (call.method == 'testScreen') return {'text': '当前屏幕核验'};
          return <String, dynamic>{};
        },
      );
      expect(calls, isNot(contains('testScreen')));
      expect(calls, isNot(contains('capture.start')));
      await tester.scrollUntilVisible(find.text('检查当前屏幕文字'), 250);
      await tester.tap(find.text('检查当前屏幕文字'));
      await tester.pumpAndSettle();
      expect(calls.where((m) => m == 'testScreen'), hasLength(1));
      expect(find.text('当前屏幕核验'), findsOneWidget);
      expect(calls, isNot(contains('setPolicies')));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('native recognition settings fit narrow large text layout', (
    tester,
  ) async {
    await mount(
      tester,
      size: const Size(320, 1000),
      scale: 2,
      handler: (call) async => <String, dynamic>{},
    );
    await tester.scrollUntilVisible(find.text('本地文字识别'), 250);
    expect(find.text('本地文字识别'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test(
    'visual observation and local flow expose recognition and region selection',
    () {
      deviceTool('ui.observe').validate({
        'recognitionMode': 'visual',
        'region': [0.0, 0.1, 1.0, 0.9],
        'query': '下一页',
      });
      deviceTool('ui.flow').validate({
        'package': 'example.app',
        'recognitionMode': 'visual',
        'steps': [
          {
            'id': 'next',
            'action': 'tap',
            'selector': {
              'text': '下一页',
              'source': 'ocr',
              'region': [0.0, 0.5, 1.0, 1.0],
            },
            'expect': {
              'kind': 'exists',
              'selector': {'text': '第2页'},
            },
          },
        ],
      });
      expect(
        () => deviceTool('ui.observe').validate({'recognitionMode': 'remote'}),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => deviceTool('ui.observe').validate({
          'region': [0, 0, 2, 1],
        }),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => deviceTool('ui.observe').validate({
          'region': [0, 0],
        }),
        throwsA(isA<FormatException>()),
      );
    },
  );

  testWidgets(
    'native OCR preference persists without overwriting application or confirmation policies',
    (tester) async {
      var policies = <String, dynamic>{
        'localOcrEnabled': false,
        'denyPackages': ['example.app'],
        'confirmMode': 'task',
      };
      final saved = <Map>[];
      await mount(
        tester,
        handler: (call) async {
          if (call.method == 'getPolicies') return policies;
          if (call.method == 'setPolicies') {
            saved.add(Map.from(call.arguments as Map));
            policies = {
              ...policies,
              ...Map<String, dynamic>.from(call.arguments as Map),
            };
            return true;
          }
          return <String, dynamic>{};
        },
      );
      final setting = find.widgetWithText(SwitchListTile, '本地文字识别');
      await tester.scrollUntilVisible(setting, 250);
      await tester.tap(setting);
      await tester.pumpAndSettle();
      expect(saved, [
        {'localOcrEnabled': true},
      ]);
      expect(policies['denyPackages'], ['example.app']);
      expect(policies['confirmMode'], 'task');
      expect(tester.widget<SwitchListTile>(setting).value, true);
      expect(tester.takeException(), isNull);
    },
  );
}

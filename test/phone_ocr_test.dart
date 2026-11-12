import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/device_engine.dart';
import 'package:ski/device_tool_catalog.dart';
import 'package:ski/embedded_engine_settings.dart';

void main() {
  testWidgets(
    'fast capture uses an explicit host action and is never enabled by loading settings',
    (tester) async {
      tester.view.physicalSize = const Size(500, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final calls = <String>[];
      var active = false;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        DeviceEngine.channel,
        (call) async {
          calls.add(call.method);
          if (call.method == 'apps') return [];
          if (call.method == 'capture.start') active = true;
          if (call.method == 'capture.stop') active = false;
          return {
            'enabled': true,
            'control': true,
            'accessibility': true,
            'packages': [],
            'localOcr': true,
            'fastCaptureSupported': true,
            'fastCaptureActive': active,
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
      expect(calls, isNot(contains('capture.start')));
      final setting = find.byKey(const ValueKey('engine-fast-capture'));
      await tester.scrollUntilVisible(
        setting,
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(setting);
      await tester.pumpAndSettle();
      expect(calls.where((method) => method == 'capture.start').length, 1);
      expect(calls, isNot(contains('configure')));
      await tester.tap(setting);
      await tester.pumpAndSettle();
      expect(calls.where((method) => method == 'capture.stop').length, 1);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('recognition choices fit a narrow screen with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      DeviceEngine.channel,
      (call) async {
        if (call.method == 'apps') return [];
        return {'recognitionMode': 'visual', 'localOcr': true, 'packages': []};
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        DeviceEngine.channel,
        null,
      ),
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(
            size: Size(320, 1000),
            textScaler: TextScaler.linear(2),
          ),
          child: EmbeddedEngineSettings(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('engine-recognition-mode')),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.text('自动选择'), findsOneWidget);
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
    'visual preference persists without changing application grants',
    (tester) async {
      tester.view.physicalSize = const Size(500, 1500);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var state = <String, dynamic>{
        'enabled': true,
        'system': false,
        'control': true,
        'shell': false,
        'packages': ['example.app'],
        'allApplications': false,
        'recognitionMode': 'auto',
        'localOcr': true,
      };
      Map<String, dynamic>? saved;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        DeviceEngine.channel,
        (call) async {
          if (call.method == 'apps') return [];
          if (call.method == 'configure') {
            saved = Map<String, dynamic>.from(call.arguments as Map);
            state = {...state, ...saved!};
          }
          return state;
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
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('engine-recognition-mode')),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('视觉优先'));
      await tester.pumpAndSettle();
      expect(saved?['recognitionMode'], 'visual');
      expect(saved?['packages'], ['example.app']);
      expect(saved?['allApplications'], false);
      expect(saved?['control'], true);
      expect(tester.takeException(), isNull);
    },
  );
}

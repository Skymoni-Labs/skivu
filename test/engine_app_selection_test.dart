import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/device_engine.dart';
import 'package:ski/embedded_engine_settings.dart';
import 'package:ski/engine_app_selection_page.dart';

void main() {
  const sampleApps = [
    {
      'name': '信息',
      'package': 'com.test.sms',
      'sortName': 'xinxi',
      'searchName': 'xin xi xinxi xx',
    },
    {
      'name': '1Password',
      'package': 'com.test.password',
      'sortName': '1password',
    },
    {
      'name': '设置',
      'package': 'com.test.settings',
      'sortName': 'shezhi',
      'searchName': 'she zhi shezhi sz',
    },
    {'name': 'Alpha', 'package': 'com.test.alpha', 'sortName': 'alpha'},
    {
      'name': '拨号',
      'package': 'com.test.dialer',
      'sortName': 'bohao',
      'searchName': 'bo hao bohao bh',
    },
  ];

  testWidgets('search and selected filter preserve hidden selections on save', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(500, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final saves = <Set<String>>[];
    await tester.pumpWidget(
      MaterialApp(
        home: EngineAppSelectionPage(
          apps: sampleApps,
          selected: {'com.test.sms', 'com.test.not_installed'},
          save: (value) async {
            saves.add(Set.of(value));
            return value;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    final ordered = ['Alpha', '拨号', '设置', '信息', '1Password'];
    for (var i = 1; i < ordered.length; i++) {
      expect(
        tester.getTopLeft(find.text(ordered[i])).dy,
        greaterThan(tester.getTopLeft(find.text(ordered[i - 1])).dy),
      );
    }
    expect(find.byKey(const ValueKey('engine-app-letter-S')), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('engine-app-search')),
      'SZ',
    );
    await tester.pumpAndSettle();
    expect(find.text('设置'), findsOneWidget);
    expect(find.text('信息'), findsNothing);
    expect(saves, isEmpty);
    await tester.tap(
      find.byKey(const ValueKey('engine-app-com.test.settings')),
    );
    await tester.pumpAndSettle();
    expect(saves.single, {
      'com.test.sms',
      'com.test.not_installed',
      'com.test.settings',
    });
    expect(find.text('SZ'), findsOneWidget);
    await tester.tap(find.byTooltip('清除搜索'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('已选 3'));
    await tester.pumpAndSettle();
    expect(find.text('设置'), findsOneWidget);
    expect(find.text('信息'), findsOneWidget);
    expect(find.text('Alpha'), findsNothing);
    await tester.enterText(
      find.byKey(const ValueKey('engine-app-search')),
      'COM.TEST.SMS',
    );
    await tester.pumpAndSettle();
    expect(find.text('信息'), findsOneWidget);
    expect(find.text('设置'), findsNothing);
    expect(saves, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'failed scope save keeps prior checkbox and search state, retry saves only packages',
    (tester) async {
      tester.view.physicalSize = const Size(500, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var snapshot = <String, dynamic>{
        'enabled': true,
        'system': true,
        'control': false,
        'shell': false,
        'packages': ['com.test.sms', 'com.test.not_installed'],
      };
      final writes = <Map<String, dynamic>>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        DeviceEngine.channel,
        (call) async {
          if (call.method == 'apps') return sampleApps;
          if (call.method == 'configure') {
            final params = Map<String, dynamic>.from(call.arguments as Map);
            writes.add(params);
            if (writes.length == 1)
              throw PlatformException(code: 'SAVE', message: '没有保存，请重试');
            snapshot = {...snapshot, ...params};
          }
          return snapshot;
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
      await tester.ensureVisible(
        find.byKey(const ValueKey('engine-choose-apps')),
      );
      await tester.tap(find.byKey(const ValueKey('engine-choose-apps')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('engine-app-search')),
        '设置',
      );
      await tester.pumpAndSettle();
      final settings = find.byKey(
        const ValueKey('engine-app-com.test.settings'),
      );
      await tester.tap(settings);
      await tester.pumpAndSettle();
      expect(find.text('没有保存，请重试'), findsOneWidget);
      expect(tester.widget<CheckboxListTile>(settings).value, false);
      expect(find.text('设置'), findsWidgets);
      await tester.tap(settings);
      await tester.pumpAndSettle();
      expect(tester.widget<CheckboxListTile>(settings).value, true);
      expect(writes, hasLength(2));
      expect(writes.last, {
        'enabled': true,
        'system': true,
        'control': false,
        'shell': false,
        'packages': [
          'com.test.sms',
          'com.test.not_installed',
          'com.test.settings',
        ],
      });
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('已选 3 个 · 共 5 个软件'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'large app list stays lazy and supports empty search on narrow large text layout',
    (tester) async {
      tester.view.physicalSize = const Size(320, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final apps = List.generate(
        300,
        (i) => {
          'name': 'Application $i',
          'package': 'com.example.app$i',
          'sortName': 'application${i.toString().padLeft(3, '0')}',
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
            child: EngineAppSelectionPage(
              apps: apps,
              selected: {},
              save: (value) async => value,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(CheckboxListTile).evaluate().length, lessThan(30));
      await tester.enterText(
        find.byKey(const ValueKey('engine-app-search')),
        'not installed',
      );
      await tester.pumpAndSettle();
      expect(find.text('没有找到匹配的软件'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('engine-app-search')),
        'com.example.app299',
      );
      await tester.pumpAndSettle();
      expect(find.text('Application 299'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

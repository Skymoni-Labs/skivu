import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/dsh_go_phone_settings.dart';
import 'package:ski/dsh_go_phone_check.dart';
import 'package:ski/product_ui.dart';
import 'package:ski/appearance.dart' show appearance;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const native = MethodChannel('dsh/phone');
  const events = MethodChannel('dsh/phone/events');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() {
    messenger.setMockMethodCallHandler(native, null);
    messenger.setMockMethodCallHandler(events, null);
  });
  testWidgets(
    'Skivu panels keep advanced features folded while scrolling in light and dark at 360px',
    (tester) async {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final originalMode = appearance.text('mode');
      addTearDown(() => appearance.set('mode', originalMode));
      final mutations = <String>[];
      messenger.setMockMethodCallHandler(events, (_) async => null);
      messenger.setMockMethodCallHandler(native, (call) async {
        if (call.method.startsWith('set') ||
            call.method.startsWith('configure'))
          mutations.add(call.method);
        if (call.method == 'status')
          return {
            'background': {
              'privileged': {'mode': 'off'},
            },
          };
        return <String, dynamic>{};
      });
      for (final brightness in Brightness.values) {
        appearance.set(
          'mode',
          brightness == Brightness.dark ? 'dark' : 'light',
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: brightness),
            home: MediaQuery(
              data: MediaQueryData(
                size: const Size(360, 780),
                textScaler: TextScaler.linear(1.4),
              ),
              child: const DshGoPhoneSettings(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(ProductScaffold), findsOneWidget);
        expect(find.byType(ProductSection), findsWidgets);
        for (final label in ['允许手机操控', '让小云查看界面并操作，随时可以暂停或停止。']) {
          final element = tester.element(find.text(label));
          final color = DefaultTextStyle.of(element).style.color!;
          final background = Theme.of(element).colorScheme.surface;
          final light = color.computeLuminance(),
              dark = background.computeLuminance();
          final contrast =
              ((light > dark ? light : dark) + 0.05) /
              ((light < dark ? light : dark) + 0.05);
          expect(
            contrast,
            greaterThanOrEqualTo(4.5),
            reason: 'Unreadable $label in $brightness',
          );
        }
        final advanced = find.byKey(
          const PageStorageKey('phone-advanced-panel'),
        );
        await tester.scrollUntilVisible(advanced, 320);
        expect(find.text('允许 Android Shell'), findsNothing);
        await tester.tap(find.text('高级能力'));
        await tester.pumpAndSettle();
        expect(find.text('允许 Android Shell'), findsOneWidget);
        expect(mutations, isEmpty);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      // Skivu can use its dark backdrop while retaining light paper surfaces.
      // The page header must still remain readable in that original theme mode.
      appearance.set('mode', 'dark');
      await tester.pumpWidget(
        MaterialApp(theme: ThemeData.light(), home: const DshGoPhoneSettings()),
      );
      await tester.pumpAndSettle();
      final heading = tester.element(find.text('手机操控'));
      expect(
        DefaultTextStyle.of(heading).style.color!.computeLuminance(),
        greaterThan(0.7),
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'native app picker searches by pinyin and saves only the selected rule',
    (tester) async {
      final originalMode = appearance.text('mode');
      appearance.set('mode', 'dark');
      addTearDown(() => appearance.set('mode', originalMode));
      var denied = <String>['missing.saved.app'];
      final writes = <Map>[];
      final methods = <String>[];
      messenger.setMockMethodCallHandler(events, (_) async => null);
      messenger.setMockMethodCallHandler(native, (call) async {
        methods.add(call.method);
        switch (call.method) {
          case 'status':
            return <String, dynamic>{};
          case 'getPolicies':
            return {
              'denyPackages': denied,
              'labels': {'missing.saved.app': '已保存的规则'},
            };
          case 'overlayPrefs':
            return {'idleOpacity': 0.8};
          case 'androidShellStatus':
            return <String, dynamic>{};
          case 'policyApps':
            return [
              {
                'name': '信息',
                'package': 'qa.message',
                'sortName': 'xinxi',
                'searchName': 'xin xi xinxi xx',
              },
            ];
          case 'setPolicies':
            writes.add(call.arguments as Map);
            denied = List<String>.from((call.arguments as Map)['denyPackages']);
            return true;
        }
        throw StateError('Unexpected settings request: ${call.method}');
      });
      await tester.pumpWidget(const MaterialApp(home: DshGoPhoneSettings()));
      await tester.pumpAndSettle();
      expect(methods, isNot(contains('policyApps')));
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('phone-excluded-apps')),
        320,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('不允许操作的软件'));
      await tester.pumpAndSettle();
      expect(methods, contains('policyApps'));
      expect(
        find.byType(ProductError),
        findsNothing,
        reason: tester
            .widgetList<ProductError>(find.byType(ProductError))
            .map((e) => e.detail)
            .join('\n'),
      );
      expect(find.text('选择小云不读取、不操作的软件'), findsOneWidget);
      final hint = find.text('长按左侧刻度，滑动定位字母');
      final hintStyle = DefaultTextStyle.of(
        tester.element(hint),
      ).style.merge(tester.widget<Text>(hint).style);
      expect(hintStyle.color!.computeLuminance(), greaterThan(0.7));
      expect(writes, isEmpty);
      await tester.enterText(
        find.byKey(const ValueKey('engine-app-search')),
        'xx',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('engine-app-qa.message')));
      await tester.pumpAndSettle();
      expect(denied.toSet(), {'missing.saved.app', 'qa.message'});
      expect(writes.single.keys, ['denyPackages']);
      await tester.tap(find.byTooltip('手动编辑包名'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.enterText(
        find.byType(TextField).last,
        'missing.saved.app\nqa.extra',
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(writes, hasLength(1));
      await tester.tap(find.byTooltip('手动编辑包名'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.enterText(
        find.byType(TextField).last,
        'missing.saved.app\nqa.extra',
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(denied.toSet(), {'missing.saved.app', 'qa.extra'});
      expect(writes, hasLength(2));
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'idle native placeholder stays hidden and task controls use the real ID',
    (tester) async {
      final pauses = <Map>[];
      messenger.setMockMethodCallHandler(events, (_) async => null);
      messenger.setMockMethodCallHandler(native, (call) async {
        if (call.method == 'status')
          return {
            'tasks': [
              {'id': 0, 'active': false},
              {'id': 42, 'active': true},
            ],
          };
        if (call.method == 'pauseTask') {
          pauses.add(call.arguments as Map);
          return true;
        }
        return <String, dynamic>{};
      });
      await tester.pumpWidget(const MaterialApp(home: DshGoPhoneSettings()));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('手机任务 42'), 300);
      await tester.ensureVisible(find.text('暂停'));
      await tester.pumpAndSettle();
      expect(find.text('手机任务 0'), findsNothing);
      await tester.tap(find.text('暂停'));
      await tester.pumpAndSettle();
      expect(pauses, [
        {'taskId': 42, 'paused': true},
      ]);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'pair dialog keeps controllers alive and cancelling never pairs',
    (tester) async {
      final pairs = <Map>[];
      messenger.setMockMethodCallHandler(events, (_) async => null);
      messenger.setMockMethodCallHandler(native, (call) async {
        if (call.method == 'status')
          return {
            'background': {
              'privileged': {'mode': 'adb'},
            },
          };
        if (call.method == 'adbPair') {
          pairs.add(call.arguments as Map);
          return {'ok': true};
        }
        return <String, dynamic>{};
      });
      await tester.pumpWidget(const MaterialApp(home: DshGoPhoneSettings()));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const PageStorageKey('phone-wireless-panel')),
        280,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('无线配对与连接'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('填写无线配对码'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('填写无线配对码'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '123456');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(pairs, isEmpty);
      await tester.tap(find.text('填写无线配对码'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '123456');
      await tester.enterText(find.byType(TextField).last, '51234');
      await tester.tap(find.text('配对'));
      await tester.pumpAndSettle();
      expect(pairs, [
        {'code': '123456', 'port': 51234},
      ]);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'interrupted tasks require the user acknowledgement of the visible batch',
    (tester) async {
      final acknowledgements = <Map>[];
      messenger.setMockMethodCallHandler(events, (_) async => null);
      messenger.setMockMethodCallHandler(native, (call) async {
        if (call.method == 'status')
          return {
            'taskInterruption': {
              'state': 'ready',
              'count': 2,
              'batchToken': 'owned-batch',
            },
          };
        if (call.method == 'acknowledgeTaskInterruption') {
          acknowledgements.add(call.arguments as Map);
          return true;
        }
        return <String, dynamic>{};
      });
      await tester.pumpWidget(const MaterialApp(home: DshGoPhoneSettings()));
      await tester.pumpAndSettle();
      expect(acknowledgements, isEmpty);
      await tester.tap(find.text('我已核对中断任务'));
      await tester.pumpAndSettle();
      expect(acknowledgements, [
        {'batchToken': 'owned-batch'},
      ]);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('diagnostics do not promote an unobserved pass', (tester) async {
    messenger.setMockMethodCallHandler(
      native,
      (call) async => {
        'accepted': true,
        'state': 'done',
        'runHandle': 'owned',
        'steps': [
          {'stage': 'device', 'state': 'pass', 'observed': true},
          {'stage': 'tap', 'state': 'pass', 'observed': false},
          {'stage': 'scroll', 'state': 'not_run', 'observed': false},
        ],
      },
    );
    await tester.pumpWidget(const MaterialApp(home: DshGoPhoneCheck()));
    await tester.pumpAndSettle();
    expect(find.text('通过'), findsOneWidget);
    expect(find.text('未核实'), findsOneWidget);
    expect(find.text('未运行'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('closing a pending diagnostic cancels only its accepted run', (
    tester,
  ) async {
    final started = Completer<Map>();
    final cancellations = <Map>[];
    messenger.setMockMethodCallHandler(native, (call) async {
      if (call.method == 'startPhoneSelfCheck') return started.future;
      if (call.method == 'cancelPhoneSelfCheck') {
        cancellations.add(call.arguments as Map);
        return {};
      }
      throw StateError('unexpected diagnostic request');
    });
    await tester.pumpWidget(const MaterialApp(home: DshGoPhoneCheck()));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    started.complete({
      'accepted': true,
      'state': 'running',
      'runHandle': 'owned-late',
    });
    await tester.pumpAndSettle();
    expect(cancellations, [
      {'v': 1, 'runHandle': 'owned-late'},
    ]);
  });
  testWidgets(
    'uses original settings channel, actual privileged mode and saved confirmation',
    (tester) async {
      var enabled = false;
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(events, (_) async => null);
      messenger.setMockMethodCallHandler(native, (call) async {
        calls.add(call);
        switch (call.method) {
          case 'status':
            return {
              'enabled': enabled,
              'statusRevision': 1,
              'background': {
                'mode': 'off',
                'privileged': {
                  'mode': 'root',
                  'keep': {'enabled': false},
                },
              },
            };
          case 'getPolicies':
            return {'confirmMode': 'task'};
          case 'androidShellStatus':
            return {'enabled': false, 'backend': 'shizuku'};
          case 'overlayPrefs':
            return {'idleOpacity': 0.8};
          case 'setEnabled':
            enabled = (call.arguments as Map)['enabled'] == true;
            return true;
        }
        throw StateError('unexpected native method');
      });
      await tester.pumpWidget(const MaterialApp(home: DshGoPhoneSettings()));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('phone-confirm-mode')),
        260,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('phone-confirm-mode')),
          matching: find.byWidgetPredicate(
            (w) =>
                w is ChoiceChip &&
                w.selected &&
                (w.label as Text).data == '按任务确认',
          ),
        ),
        findsOneWidget,
      );
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('phone-background-mode')),
        260,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('phone-background-mode')),
          matching: find.byWidgetPredicate(
            (w) =>
                w is ChoiceChip &&
                w.selected &&
                (w.label as Text).data == 'Root',
          ),
        ),
        findsOneWidget,
      );
      await tester.scrollUntilVisible(find.text('允许手机操控'), -320);
      await tester.tap(find.widgetWithText(SwitchListTile, '允许手机操控'));
      await tester.pumpAndSettle();
      expect(enabled, isTrue);
      expect(calls.where((c) => c.method == 'setEnabled'), hasLength(1));
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('pending native write blocks duplicate user toggles', (
    tester,
  ) async {
    final completion = Completer<bool>();
    var writes = 0;
    messenger.setMockMethodCallHandler(events, (_) async => null);
    messenger.setMockMethodCallHandler(native, (call) async {
      if (call.method == 'setEnabled') {
        writes++;
        return completion.future;
      }
      if (call.method == 'status') return {'enabled': false};
      if (call.method == 'getPolicies') return {'confirmMode': 'ask'};
      if (call.method == 'overlayPrefs') return {'idleOpacity': 0.8};
      return {'enabled': false, 'backend': 'shizuku'};
    });
    await tester.pumpWidget(const MaterialApp(home: DshGoPhoneSettings()));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch).first);
    await tester.pump();
    await tester.tap(find.byType(Switch).first);
    await tester.pump();
    expect(writes, 1);
    completion.complete(true);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}

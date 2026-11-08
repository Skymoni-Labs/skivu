import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/background_alarms_page.dart';
import 'package:ski/device_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(
    () => messenger.setMockMethodCallHandler(DeviceEngine.channel, null),
  );
  testWidgets(
    'capability inspection never opens authorization until a user tap',
    (tester) async {
      var opens = 0;
      messenger.setMockMethodCallHandler(DeviceEngine.channel, (call) async {
        if (call.method == 'status')
          return {
            'androidSdk': 37,
            'alarmReady': false,
            'exactAlarms': false,
            'alarmNotifications': true,
          };
        if (call.method == 'alarms.list') return [];
        expect(call.method, 'authorization');
        opens++;
        return {};
      });
      await tester.pumpWidget(const MaterialApp(home: BackgroundAlarmsPage()));
      await tester.pumpAndSettle();
      expect(opens, 0);
      expect(find.text('尚未就绪'), findsOneWidget);
      await tester.tap(find.text('精确闹钟'));
      await tester.pumpAndSettle();
      expect(opens, 1);
    },
  );
  testWidgets(
    'cancelling one owned resource independently reads back its state',
    (tester) async {
      var cancelled = false, mutations = 0;
      messenger.setMockMethodCallHandler(DeviceEngine.channel, (call) async {
        if (call.method == 'status')
          return {
            'androidSdk': 37,
            'alarmReady': true,
            'exactAlarms': true,
            'alarmNotifications': true,
          };
        if (call.method == 'alarms.cancel') {
          expect((call.arguments as Map)['id'], 'bg-1');
          mutations++;
          cancelled = true;
          return {'id': 'bg-1', 'enabled': false};
        }
        expect(call.method, 'alarms.list');
        return [
          {
            'id': 'bg-1',
            'kind': 'alarm',
            'label': '测试提醒',
            'enabled': !cancelled,
            'state': cancelled ? 'cancelled' : 'scheduled',
            'nextAt': DateTime(2030, 1, 1, 7, 30).millisecondsSinceEpoch,
            'days': [],
          },
        ];
      });
      await tester.pumpWidget(const MaterialApp(home: BackgroundAlarmsPage()));
      await tester.pumpAndSettle();
      expect(mutations, 0);
      await tester.ensureVisible(find.text('取消提醒'));
      await tester.tap(find.text('取消提醒'));
      await tester.pumpAndSettle();
      expect(mutations, 1);
      expect(find.text('已取消'), findsOneWidget);
      expect(find.text('取消提醒'), findsNothing);
    },
  );
}

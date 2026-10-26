import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ski/device_task_journal.dart';

Map<String, dynamic> receipt(int id, {String state = 'completed'}) => {
  'taskId': 'device_$id',
  'pluginId': 'test.device',
  'digest': 'a' * 64,
  'state': state,
  'summary': '保存并读回测试内容',
  'actions': 3,
  'rounds': 3,
  'errorCode': null,
};
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'completed task receipts remain queryable after process recreation',
    () async {
      await DeviceTaskJournal().save({'device_1': receipt(1)});
      final restored = await DeviceTaskJournal().restore();
      expect(restored['device_1']!['state'], 'completed');
      expect(restored['device_1']!['actions'], 3);
    },
  );
  test(
    'a process death converts pending work to reconciliation without resuming',
    () async {
      await DeviceTaskJournal().save({
        'device_2': receipt(2, state: 'executing'),
      });
      final restored = await DeviceTaskJournal().restore();
      expect(restored['device_2']!['state'], 'review_required');
      expect(restored['device_2']!['errorCode'], 'PROCESS_RESTART');
    },
  );
  test(
    'receipt persistence excludes credentials, goals and arbitrary plugin fields',
    () async {
      await DeviceTaskJournal().save({
        'device_3': {
          ...receipt(3),
          'token': 'must-not-persist',
          'goal': 'private-goal',
        },
      });
      final raw = (await SharedPreferences.getInstance()).getString(
        DeviceTaskJournal.key,
      )!;
      expect(raw, isNot(contains('must-not-persist')));
      expect(raw, isNot(contains('private-goal')));
    },
  );
  test(
    'corrupt and oversized journals do not block startup or invent results',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(DeviceTaskJournal.key, 'not-json');
      expect(await DeviceTaskJournal().restore(), isEmpty);
      await prefs.setString(
        DeviceTaskJournal.key,
        jsonEncode(List.generate(41, (i) => receipt(i))),
      );
      expect(await DeviceTaskJournal().restore(), isEmpty);
    },
  );
  test('only the newest forty bounded receipts are retained', () async {
    await DeviceTaskJournal().save({
      for (var i = 0; i < 45; i++) 'device_$i': receipt(i),
    });
    final restored = await DeviceTaskJournal().restore();
    expect(restored.length, 40);
    expect(restored.containsKey('device_0'), false);
    expect(restored.containsKey('device_44'), true);
  });
}

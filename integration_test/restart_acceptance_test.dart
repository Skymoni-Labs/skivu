import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ski/main.dart' as app;
import 'package:ski/state.dart';
import 'package:ski/model_settings.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'new Android process restores role, model and failure history from real storage',
    (tester) async {
      await app.main();
      for (var i = 0; i < 24; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(
        demo.personas.any((role) => role.name == '验收伙伴20261027-已修改'),
        true,
      );
      final profile = modelSettings.connections.singleWhere(
        (connection) => connection.name == '验收连接20261027',
      );
      expect(profile.model, 'acceptance-offline-fixture');
      expect(
        await modelSettings.keyFor(profile.id),
        'acceptance-fixture-not-a-real-secret',
      );
      expect(
        demo.conversations
            .expand((chat) => chat.messages)
            .any((message) => message.text.contains('验收离线消息')),
        true,
      );
      final data = {
        'result': 'passed',
        'checks': [
          'role persisted',
          'model persisted',
          'secure fixture key persisted',
          'user failure-history persisted',
        ],
        'note':
            'Actual fresh Android process; no real credential or external model was used',
      };
      final dir = await getApplicationSupportDirectory();
      await File(
        '${dir.path}/acceptance-restart.json',
      ).writeAsString(jsonEncode(data));
      binding.reportData = data;
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

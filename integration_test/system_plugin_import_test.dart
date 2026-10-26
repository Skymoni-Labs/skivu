import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ski/main.dart' as app;
import 'package:ski/open_plugin.dart';

/// The host driver selects the synthetic .json file in Android DocumentsUI.
/// No picker or package parser is mocked in this test.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Android file import, explicit enable, update and erase',
    (tester) async {
      const id = 'org.skivu.device-control';
      Future<void> frames([int n = 4]) async {
        for (var i = 0; i < n; i++) {
          await tester.pump(const Duration(milliseconds: 250));
        }
      }

      Future<void> tap(Finder finder) async {
        await tester.ensureVisible(finder);
        await tester.tap(finder);
        await frames();
      }

      Future<void> importFile(String title) async {
        for (var i = 0; i < 120; i++) {
          final button = tester.widget<TextButton>(
            find.widgetWithText(TextButton, '导入插件'),
          );
          if (button.onPressed != null) break;
          await frames(2);
        }
        debugPrint('ACCEPTANCE WAIT_SYSTEM_PLUGIN_PICKER');
        await tap(find.text('导入插件'));
        for (var i = 0; i < 160 && find.text(title).evaluate().isEmpty; i++) {
          await frames(2);
        }
        expect(find.text(title), findsOneWidget);
        await tap(find.widgetWithText(FilledButton, '安装'));
        await frames(4);
        expect(openPlugins.records[id]?.manifest.version, '0.2.0');
        expect(openPlugins.records[id]?.authorized, false);
      }

      await app.main();
      await frames(24);
      app.appNavigator.currentState!.pushNamed('/open-plugins');
      await frames(8);
      await importFile('安装 手机操控？');
      await tap(find.text('启用'));
      expect(find.textContaining('直接操控授权会持续有效'), findsOneWidget);
      await tap(find.text('同意并启用'));
      expect(openPlugins.records[id]!.authorized, true);
      await writePluginData(
        id,
        'acceptance-marker',
        jsonEncode({'fixture': true}),
      );
      await tap(find.text('停用'));
      expect(openPlugins.records[id]!.authorized, false);
      await importFile('更新 手机操控？');
      expect(
        await readPluginData(id, 'acceptance-marker'),
        contains('fixture'),
      );
      await tap(find.widgetWithText(TextButton, '卸载'));
      await tap(find.byType(CheckboxListTile));
      await tap(find.widgetWithText(FilledButton, '卸载'));
      await frames(4);
      expect(openPlugins.records.containsKey(id), false);
      expect(await readPluginData(id, 'acceptance-marker'), isNull);
      expect(tester.takeException(), isNull);
      binding.reportData = {
        'result': 'passed',
        'checks': [
          'Android DocumentsUI selected the real independent JSON package twice',
          'install stayed disabled until explicit ongoing-control disclosure',
          'enable and disable updated actual registry state',
          'update reset authorization and retained synthetic plugin data',
          'uninstall with erase removed registry and synthetic plugin data',
        ],
        'model': 'no inference or production write',
      };
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );
}

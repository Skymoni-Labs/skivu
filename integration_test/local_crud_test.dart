import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ski/main.dart' as app;
import 'package:ski/model_settings.dart';
import 'package:ski/state.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'actual Android model CRUD, secure erasure and role deletion',
    (tester) async {
      const secure = FlutterSecureStorage();
      final checks = <String>[];
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

      Future<void> deleteModel(String name) async {
        await tap(find.byTooltip('删除 $name'));
        await tap(find.widgetWithText(FilledButton, '删除'));
        await frames();
      }

      Future<void> add(String name, String key) async {
        await tap(find.text('添加模型连接'));
        for (final pair in {
          '连接名称': name,
          'API 地址': 'http://127.0.0.1:9/v1',
          'API Key': key,
          '模型 ID': 'acceptance-offline-fixture',
        }.entries) {
          await tester.enterText(
            find.widgetWithText(TextFormField, pair.key),
            pair.value,
          );
        }
        await tap(find.text('保存连接'));
        await frames();
      }

      await app.main();
      await frames(24);
      app.appNavigator.currentState!.pushNamed('/settings/models');
      await frames();
      // Refuse to run destructive tests against a profile that isn't our fixture.
      expect(
        modelSettings.connections.every(
          (p) =>
              p.name.startsWith('验收连接20261027') ||
              p.name.startsWith('acceptance-model-'),
        ),
        true,
        reason:
            'Use only an isolated acceptance package with synthetic profiles',
      );
      for (final profile in modelSettings.connections.toList()) {
        await deleteModel(profile.name);
      }
      await add('acceptance-model-a', 'fixture-key-a-not-real');
      await add('acceptance-model-b', 'fixture-key-b-not-real');
      final a = modelSettings.connections.firstWhere(
        (p) => p.name == 'acceptance-model-a',
      );
      final b = modelSettings.connections.firstWhere(
        (p) => p.name == 'acceptance-model-b',
      );
      expect(modelSettings.activeId, a.id);
      await tap(find.text('使用此模型'));
      expect(modelSettings.activeId, b.id);
      checks.add('two real UI saves and model selection');
      final oldCredential = b.credentialId!;
      expect(
        await secure.read(key: 'skivu.api.$oldCredential'),
        'fixture-key-b-not-real',
      );
      await tap(find.text('配置').last);
      await tester.enterText(
        find.widgetWithText(TextFormField, '连接名称'),
        'acceptance-model-b-edited',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'API Key'),
        'fixture-key-b2-not-real',
      );
      await tap(find.text('保存连接'));
      await frames();
      expect(await modelSettings.keyFor(b.id), 'fixture-key-b2-not-real');
      expect(await secure.read(key: 'skivu.api.$oldCredential'), isNull);
      checks.add(
        'edit retains ID and removes replaced key from actual Android secure storage',
      );
      await deleteModel(a.name);
      expect(modelSettings.activeId, b.id);
      final latest = modelSettings.connections.single;
      final credential = latest.credentialId!;
      await deleteModel(latest.name);
      expect(modelSettings.connections, isEmpty);
      expect(modelSettings.activeId, isNull);
      expect(await secure.read(key: 'skivu.api.$credential'), isNull);
      checks.add(
        'delete inactive and final active model, including actual secure key erasure',
      );
      app.appNavigator.currentState!.pushNamed('/characters');
      await frames();
      final originalIds = demo.personas.map((p) => p.id).toSet();
      await tap(find.text('创建角色'));
      await tester.enterText(
        find.widgetWithText(TextFormField, '角色名称'),
        '验收删除角色',
      );
      await tap(find.text('保存角色'));
      final added = demo.personas.firstWhere((p) => p.name == '验收删除角色');
      await tap(find.byTooltip('角色操作：验收删除角色'));
      await tap(find.text('删除角色'));
      await tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(FilledButton),
        ),
      );
      expect(demo.personas.any((p) => p.id == added.id), false);
      expect(demo.personas.map((p) => p.id).toSet(), originalIds);
      expect(demo.conversations.any((c) => c.personaId == added.id), false);
      checks.add(
        'role UI deletion removes only the synthetic role and its chats',
      );
      expect(tester.takeException(), isNull);
      binding.reportData = {
        'result': 'passed',
        'checks': checks,
        'model':
            'no inference; all keys are explicit synthetic fixture strings',
      };
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

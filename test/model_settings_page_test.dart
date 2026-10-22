import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ski/model_connection.dart';
import 'package:ski/model_settings.dart';
import 'package:ski/model_settings_page.dart';
import 'package:ski/settings_home.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'API keys stay out of ordinary preferences and survive profile updates',
    () async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      final store = ModelSettings();
      await store.restore();
      const c = ModelConnection(
        id: 'profile-1',
        name: '主模型',
        provider: '自定义',
        protocol: ApiProtocol.chat,
        address: 'https://models.example/v1',
        model: 'test-model',
      );
      await store.save(c, 'test-private-key');
      final prefs = await SharedPreferences.getInstance();
      final json = prefs.getString('skivu.models.v1')!;
      expect(json, isNot(contains('test-private-key')));
      expect(await store.keyFor(c.id), 'test-private-key');
      final restarted = ModelSettings();
      await restarted.restore();
      expect(restarted.active!.model, 'test-model');
      expect(await restarted.keyFor(c.id), 'test-private-key');
      await restarted.save(c, 'replacement-private-key');
      expect(await restarted.keyFor(c.id), 'replacement-private-key');
      expect(
        jsonEncode((await SharedPreferences.getInstance()).getKeys().toList()),
        isNot(contains('private-key')),
      );
      await restarted.remove(c.id);
      expect(restarted.connections, isEmpty);
      expect(await restarted.keyFor(c.id), isEmpty);
      expect(await const FlutterSecureStorage().readAll(), isEmpty);
      restarted.dispose();
      store.dispose();
    },
  );

  testWidgets(
    'settings and model editor fit a narrow screen with enlarged text and keyboard',
    (tester) async {
      tester.view.physicalSize = const Size(320, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 740),
              textScaler: TextScaler.linear(1.2),
            ),
            child: Scaffold(
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: SettingsHome(go: (_) {}),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('登录中转站'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              padding: EdgeInsets.all(20),
              child: ModelSettingsPage(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('添加模型连接'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextFormField, 'API 地址'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextFormField, 'API 地址'));
      tester.view.viewInsets = const FakeViewPadding(bottom: 270);
      await tester.pumpAndSettle();
      expect(find.text('保存连接'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('保存连接'));
      await tester.pumpAndSettle();
      expect(find.textContaining('请填写有效'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

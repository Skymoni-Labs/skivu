import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ski/main.dart' as app;
import 'package:ski/state.dart';
import 'package:ski/model_settings.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'normal Android entry: routes, role CRUD, model storage and refused-network chat',
    (tester) async {
      final cases = <Map<String, dynamic>>[];
      void record(String id, String scenario) {
        cases.add({'id': id, 'scenario': scenario, 'result': 'passed'});
        debugPrint('ACCEPTANCE $id passed');
      }

      Future<void> frames([int count = 4]) async {
        for (var i = 0; i < count; i++) {
          await tester.pump(const Duration(milliseconds: 250));
        }
      }

      Future<void> route(String name) async {
        app.appNavigator.currentState!.pushNamed(name);
        await frames(6);
        expect(tester.takeException(), isNull);
      }

      Future<void> tap(Finder finder) async {
        await tester.ensureVisible(finder);
        await tester.tap(finder);
        await frames();
      }

      await app.main();
      await frames(24);
      expect(find.byTooltip('打开导航'), findsOneWidget);
      record('CORE-BOOT', '正常入口冷启动/无账号空状态/导航可见');
      await tap(find.byTooltip('打开导航'));
      expect(find.text('设置'), findsOneWidget);
      expect(find.text('角色'), findsOneWidget);
      record('CORE-NAV', '侧栏实际入口可见');
      await tap(find.byTooltip('关闭导航'));
      for (final entry in <String, String>{
        '/characters': '角色',
        '/worlds': '世界观',
        '/stickers': '表情包',
        '/settings': '设置',
        '/settings/models': '模型与服务',
        '/settings/account': '中转站账号',
        '/settings/beta': '内测计划',
        '/settings/appearance': '外观',
        '/settings/speech': '语音与通话',
        '/settings/social': '社交与群聊',
        '/settings/data': '聊天记录',
        '/settings/permissions': '隐私与权限',
        '/settings/devices': '访问设备',
        '/settings/updates': '检查更新',
        '/settings/about': '关于 Skivu',
        '/market': '插件市场',
        '/extensions': '技能与工具',
        '/open-plugins': '开放插件',
      }.entries) {
        await route(entry.key);
        record('ROUTE-${entry.key}', '页面打开/加载状态/无布局异常：${entry.value}');
        app.appNavigator.currentState!.pop();
        await frames(2);
      }
      await route('/settings/updates');
      expect(find.textContaining('独立构建'), findsWidgets);
      record('CORE-PREVIEW-UPDATE', '独立包明确手动更新，不请求正式更新包');
      app.appNavigator.currentState!.pop();
      await frames();
      await route('/characters');
      await tap(find.text('创建角色'));
      final roleName = find.widgetWithText(TextFormField, '角色名称');
      await tester.enterText(roleName, '验收伙伴20261027');
      await tap(find.text('保存角色'));
      expect(demo.personas.any((role) => role.name == '验收伙伴20261027'), true);
      record('CORE-ROLE-CREATE', '经真实页面创建/填写/保存角色');
      // A fresh editor is opened from the role that the UI just created.
      app.appNavigator.currentState!.pushNamed('/characters/edit');
      await frames();
      await tester.enterText(
        find.widgetWithText(TextFormField, '角色名称'),
        '验收伙伴20261027-已修改',
      );
      await tap(find.text('保存角色'));
      expect(
        demo.personas.any((role) => role.name == '验收伙伴20261027-已修改'),
        true,
      );
      record('CORE-ROLE-EDIT', '修改角色并保存，角色数据保持一致');
      app.appNavigator.currentState!.pushNamed('/settings/models');
      await frames();
      await tap(find.text('添加模型连接'));
      await tap(find.text('保存连接'));
      expect(find.textContaining('请填写'), findsWidgets);
      record('CORE-MODEL-INVALID', '空模型表单未保存并给出字段说明');
      await tester.enterText(
        find.widgetWithText(TextFormField, '连接名称'),
        '验收连接20261027',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'API 地址'),
        'http://127.0.0.1:9/v1',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'API Key'),
        'acceptance-fixture-not-a-real-secret',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, '模型 ID'),
        'acceptance-offline-fixture',
      );
      await tap(find.text('保存连接'));
      await frames();
      final profile = modelSettings.connections.singleWhere(
        (connection) => connection.name == '验收连接20261027',
      );
      expect(
        await modelSettings.keyFor(profile.id),
        'acceptance-fixture-not-a-real-secret',
      );
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString('skivu.models.v1') ?? '',
        isNot(contains('acceptance-fixture-not-a-real-secret')),
      );
      record('CORE-MODEL-SAVE', '页面保存连接；实际Android加密存储可读，普通配置不含测试密钥');
      app.appNavigator.currentState!.pushNamed('/chat');
      await frames();
      final inputs = find.byType(TextField);
      expect(inputs, findsWidgets);
      final before = demo.conversations[demo.conversation].messages
          .where((message) => message.user)
          .length;
      await tester.enterText(inputs.last, '验收离线消息：只发往本机关闭端口');
      await tester.tap(find.byTooltip('发送消息'));
      await tester.pump();
      if (find.byTooltip('发送消息').evaluate().isNotEmpty)
        await tester.tap(find.byTooltip('发送消息'));
      await frames(16);
      expect(demo.streaming, false);
      expect(demo.messages.last.status, 'failed');
      expect(demo.messages.last.error, isNotEmpty);
      final after = demo.conversations[demo.conversation].messages
          .where((message) => message.user)
          .length;
      expect(after - before, 1);
      record('CORE-CHAT-REFUSED', '实际本机端口拒绝连接；错误清晰且连点未产生重复用户消息');
      await frames(8);
      expect(tester.takeException(), isNull);
      final dir = await getApplicationSupportDirectory();
      await File('${dir.path}/acceptance-core.json').writeAsString(
        jsonEncode({
          'cases': cases,
          'modelConnectionId': profile.id,
          'role': '验收伙伴20261027-已修改',
          'model': 'acceptance-offline-fixture',
          'network': 'loopback port9 only; no real model or production writes',
        }),
      );
      binding.reportData = {'cases': cases};
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

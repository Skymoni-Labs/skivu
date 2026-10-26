import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ski/open_plugin.dart';
import 'package:ski/open_plugin_companion_ui.dart';
import 'package:ski/state.dart';
import 'package:ski/chat.dart';
import 'package:ski/open_plugin_page.dart';
import 'open_plugin_test.dart' show TestPaths;
import 'open_plugin_companion_test.dart' show fixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    temp = await Directory.systemTemp.createTemp('skivu-role-ui-');
    PathProviderPlatform.instance = TestPaths(temp.path);
    openPlugins.records.clear();
    openPlugins.roleBindings.clear();
    final p = fixture();
    openPlugins.records[p.manifest.id] = OpenPluginRecord(
      p,
      enabled: true,
      grantedDigest: p.digest,
    );
  });
  tearDown(() async {
    openPlugins.records.clear();
    openPlugins.roleBindings.clear();
    final target = temp.resolveSymbolicLinksSync();
    expect(
      target,
      startsWith(
        Directory.systemTemp.resolveSymbolicLinksSync() +
            Platform.pathSeparator,
      ),
    );
    await temp.delete(recursive: true);
  });
  Future<void> open(WidgetTester tester, {double textScale = 1}) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (c, child) => MediaQuery(
          data: MediaQuery.of(
            c,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (c) => Column(
              children: [
                const Text('原生聊天仍在这里'),
                TextButton(
                  onPressed: () => showRoleCompanions(c, demo.role),
                  child: const Text('角色随身插件'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('角色随身插件'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'bind is per role, starts manually and disable preserves plugin records',
    (tester) async {
      final role = demo.role;
      await tester.runAsync(
        () => writePluginData('test.free-plugin', 'storage', '{"kept":true}'),
      );
      await open(tester);
      expect(openPlugins.chatSurface, isNull);
      expect(openPlugins.bindingFor('test.free-plugin', role.id), isNull);
      expect(find.text('原生聊天仍在这里'), findsOneWidget);
      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();
      expect(openPlugins.bindingFor('test.free-plugin', role.id), {
        'scope': 'story',
        'chat': false,
      });
      expect(
        openPlugins.bindingFor('test.free-plugin', 'another-role'),
        isNull,
      );
      final automatic = find.text('允许随正常聊天读写本机记录');
      await tester.ensureVisible(automatic);
      await tester.tap(automatic);
      await tester.pumpAndSettle();
      expect(
        openPlugins.bindingFor('test.free-plugin', role.id)!['chat'],
        true,
      );
      await tester.ensureVisible(find.byType(Switch).first);
      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();
      expect(openPlugins.bindingFor('test.free-plugin', role.id), isNull);
      expect(
        await tester.runAsync(
          () => readPluginData('test.free-plugin', 'storage'),
        ),
        '{"kept":true}',
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'return to normal chat keeps the existing draft and never sends a message',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final value = jsonDecode(fixture().raw) as Map;
      value['manifest']['permissions'].add('chat.write');
      final package = OpenPluginPackage.parse(jsonEncode(value));
      final record = OpenPluginRecord(
        package,
        enabled: true,
        grantedDigest: package.digest,
      );
      openPlugins.records[record.manifest.id] = record;
      final chat = demo.conversations[demo.conversation],
          count = chat.messages.length;
      demo.saveDraft(chat, '原来尚未发送的内容');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatPage(
              openWorkspace: () {},
              openCall: () {},
              openModels: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final context = tester.element(find.byType(ChatPage));
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => OpenPluginPage(record: record, registry: openPlugins),
        ),
      );
      await tester.pumpAndSettle();
      final dynamic state = tester.state(find.byType(OpenPluginPage));
      await tester.runAsync(
        () => state.hostCall('ui.chatDraft', {'text': '我想聊聊这条手机记录。'}),
      );
      await tester.pumpAndSettle();
      expect(find.byType(OpenPluginPage), findsNothing);
      expect(chat.messages.length, count);
      expect(chat.draft, '原来尚未发送的内容\n\n我想聊聊这条手机记录。');
      final input = tester
          .widgetList<TextField>(find.byType(TextField))
          .firstWhere((f) => f.controller?.text.contains('原来尚未发送') ?? false);
      expect(input.controller!.text, chat.draft);
      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = null;
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('role companion settings fit a narrow enlarged-text screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await openPlugins.bindRole('test.free-plugin', demo.role.id, enabled: true);
    await open(tester, textScale: 1.7);
    await tester.ensureVisible(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}

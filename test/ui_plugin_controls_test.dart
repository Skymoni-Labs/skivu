import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ski/state.dart';
import 'package:ski/ui_plugins.dart';
import 'package:ski/ui_plugins_page.dart';
import 'package:ski/plugin_market.dart';
import 'real_chat_store_test.dart' show MemoryChats;
import 'plugin_market_test.dart' show installedMarket;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'enable, replace, disable and restart preserve the original chat archive',
    () async {
      final store = DemoStore(storage: MemoryChats());
      await store.restore();
      store.newChat(personaId: store.personas.first.id);
      store.messages.add(Message(true, '保持此段历史'));
      store.conversations[store.conversation].draft = '未发送草稿';
      final archive = store.exportChats(), model = UiPluginSettings();
      expect(await model.setEnabled(ChatUiMode.qq, true), isTrue);
      expect(model.mode, ChatUiMode.qq);
      expect(await model.setEnabled(ChatUiMode.wechat, true), isTrue);
      final revision = model.homeRevision;
      // A late off event from the previous presenter must not disable WeChat.
      expect(await model.setEnabled(ChatUiMode.qq, false), isTrue);
      expect(model.mode, ChatUiMode.wechat);
      expect(model.homeRevision, revision);
      final restored = UiPluginSettings();
      await restored.restore();
      expect(restored.mode, ChatUiMode.wechat);
      expect(await model.setEnabled(ChatUiMode.wechat, false), isTrue);
      await restored.restore();
      expect(restored.mode, ChatUiMode.classic);
      expect(store.exportChats(), archive);
      model.dispose();
      restored.dispose();
      store.dispose();
    },
  );
  test('queued toggles keep the most recently enabled plugin active', () async {
    final model = UiPluginSettings();
    final operations = [
      model.setEnabled(ChatUiMode.qq, true),
      model.setEnabled(ChatUiMode.wechat, true),
      model.setEnabled(ChatUiMode.qq, false),
    ];
    expect(model.busy, isTrue);
    expect(await Future.wait(operations), everyElement(isTrue));
    expect(model.busy, isFalse);
    expect(model.mode, ChatUiMode.wechat);
    model.dispose();
  });
  testWidgets('two compact sidebar choices can be enabled and switched off', (
    tester,
  ) async {
    final model = UiPluginSettings(), routes = <String>[];
    final market = (await tester.runAsync(installedMarket))!;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 230,
              child: MediaQuery(
                data: const MediaQueryData(textScaler: TextScaler.linear(1.4)),
                child: UiPluginOptions(
                  compact: true,
                  preferences: model,
                  market: market,
                  go: routes.add,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.byIcon(Icons.extension_outlined), findsNWidgets(2));
    final qq = find.byKey(const ValueKey('sidebar-plugin-qq'));
    final wechat = find.byKey(const ValueKey('sidebar-plugin-wechat'));
    await tester.tap(qq);
    await tester.pumpAndSettle();
    expect(model.mode, ChatUiMode.qq);
    await tester.tap(qq);
    await tester.pumpAndSettle();
    expect(model.mode, ChatUiMode.classic);
    await tester.tap(wechat);
    await tester.pumpAndSettle();
    expect(model.mode, ChatUiMode.wechat);
    expect(model.mode, isNot(ChatUiMode.qq));
    expect(routes, ['/chat', '/chat', '/chat']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    model.dispose();
    market.dispose();
  });
  testWidgets(
    'sidebar removes uninstalled cards and restores them only after installation',
    (tester) async {
      final model = UiPluginSettings();
      final market = (await tester.runAsync(installedMarket))!;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 230,
              child: UiPluginOptions(
                compact: true,
                preferences: model,
                market: market,
                go: (_) {},
              ),
            ),
          ),
        ),
      );
      final card = find.byKey(const ValueKey('sidebar-plugin-wechat'));
      expect(card, findsOneWidget);
      await tester.tap(card);
      await tester.pumpAndSettle();
      expect(model.mode, ChatUiMode.wechat);
      await tester.tap(
        find.byKey(const ValueKey('sidebar-plugin-menu-wechat')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('卸载插件'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(card, findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('sidebar-plugin-menu-wechat')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('卸载插件'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('卸载'));
      await tester.pumpAndSettle();
      expect(card, findsNothing);
      expect(model.mode, ChatUiMode.classic);
      final restored = PluginMarket();
      await restored.restore();
      expect(restored.installedFor(ChatUiMode.wechat), isNull);
      expect(restored.installedFor(ChatUiMode.qq), isNotNull);
      final available = market.catalog.singleWhere(
        (p) => p.mode == ChatUiMode.wechat,
      );
      expect(await tester.runAsync(() => market.install(available)), isTrue);
      await tester.pumpAndSettle();
      expect(card, findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      restored.dispose();
      model.dispose();
      market.dispose();
    },
  );
  testWidgets(
    'plugin market contains exactly two toggles and no classic card',
    (tester) async {
      final model = UiPluginSettings();
      final market = (await tester.runAsync(installedMarket))!;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: SizedBox(
                width: 260,
                child: UiPluginsPage(
                  preferences: model,
                  market: market,
                  autoRefresh: false,
                  go: (_) {},
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.byType(SwitchListTile), findsNWidgets(2));
      expect(find.text('QQ'), findsOneWidget);
      expect(find.text('微信'), findsOneWidget);
      expect(find.text('Skivu 原版'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
      market.dispose();
    },
  );
}

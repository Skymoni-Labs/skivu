import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:ski/chat_api.dart';
import 'package:ski/chat_thinking_toggle.dart';
import 'package:ski/model_connection.dart';
import 'package:ski/model_settings.dart';
import 'package:ski/state.dart';

import 'real_chat_store_test.dart' show MemoryChats;

class ThinkingPreferences extends InMemorySharedPreferencesStore {
  ThinkingPreferences() : super.empty();
  bool failNextWrite = false;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (failNextWrite) {
      failNextWrite = false;
      return false;
    }
    return super.setValue(valueType, key, value);
  }
}

ModelConnection profile({
  String id = 'direct-deepseek',
  String address = 'https://api.deepseek.com/v1',
  String model = 'deepseek-flash',
  bool? thinking,
}) => ModelConnection(
  id: id,
  name: id,
  provider: '自定义兼容接口',
  protocol: ApiProtocol.chat,
  address: address,
  model: model,
  thinkingEnabled: thinking,
);

Future<DemoStore> storeFor(ModelConnection connection) async {
  final models = ModelSettings();
  await models.save(connection, 'thinking-widget-fixture');
  final store = DemoStore(
    settings: models,
    storage: MemoryChats(),
    api: ChatApi(
      clientFactory: () => MockClient((request) async {
        fail('Changing the thinking preference must not request a model.');
      }),
    ),
  );
  addTearDown(store.dispose);
  addTearDown(models.dispose);
  return store;
}

Widget page(DemoStore store) => MaterialApp(
  home: Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: ChatThinkingToggle(store: store),
    ),
  ),
);

Semantics thinkingSemantics(WidgetTester tester) => tester.widget<Semantics>(
  find.byWidgetPredicate(
    (widget) => widget is Semantics && widget.properties.toggled != null,
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets('the provider default can be toggled and survives reopening', (
    tester,
  ) async {
    final store = await storeFor(profile());
    await tester.pumpWidget(page(store));
    expect(find.text('深度思考'), findsOneWidget);
    expect(store.models.active!.thinkingEnabled, isNull);
    expect(store.models.active!.effectiveThinkingEnabled, isTrue);
    expect(thinkingSemantics(tester).properties.toggled, isTrue);
    expect(thinkingSemantics(tester).properties.enabled, isTrue);
    expect(
      tester.widgetList<Tooltip>(find.byType(Tooltip)).map((w) => w.message),
      contains(contains('跟随服务商')),
    );

    await tester.tap(find.text('深度思考'));
    await tester.pumpAndSettle();
    expect(store.models.active!.thinkingEnabled, isFalse);
    expect(thinkingSemantics(tester).properties.toggled, isFalse);
    expect(
      await store.models.keyFor(store.models.activeId!),
      'thinking-widget-fixture',
    );
    final restarted = ModelSettings();
    addTearDown(restarted.dispose);
    await restarted.restore();
    expect(restarted.active!.thinkingEnabled, isFalse);

    await tester.tap(find.text('深度思考'));
    await tester.pumpAndSettle();
    expect(store.models.active!.thinkingEnabled, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an explicit disabled DeepSeek Pro profile can be enabled', (
    tester,
  ) async {
    final store = await storeFor(
      profile(model: 'deepseek-v4-pro', thinking: false),
    );
    await tester.pumpWidget(page(store));
    await tester.tap(find.text('深度思考'));
    await tester.pumpAndSettle();
    expect(store.models.active!.thinkingEnabled, isTrue);
    expect(tester.takeException(), isNull);
  });

  for (final connection in [
    profile(address: 'https://relay.example/v1'),
    profile(model: 'unknown-model'),
  ]) {
    testWidgets(
      'an unsupported ${connection.address}/${connection.model} stays disabled',
      (tester) async {
        final store = await storeFor(connection);
        await tester.pumpWidget(page(store));
        expect(find.byTooltip('当前连接暂未适配思考开关'), findsOneWidget);
        expect(thinkingSemantics(tester).properties.enabled, isFalse);
        expect(
          tester
              .widget<TextButton>(
                find.byKey(const ValueKey('chat-thinking-toggle')),
              )
              .onPressed,
          isNull,
        );
        await tester.tap(find.text('深度思考'));
        await tester.pumpAndSettle();
        expect(store.models.active!.thinkingEnabled, isNull);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('account routing does not change the saved direct connection', (
    tester,
  ) async {
    final store = await storeFor(profile());
    store.useAccount = true;
    await tester.pumpWidget(page(store));
    expect(find.byTooltip('当前连接暂未适配思考开关'), findsOneWidget);
    await tester.tap(find.text('深度思考'));
    await tester.pumpAndSettle();
    expect(store.models.active!.thinkingEnabled, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a running reply disables changes until generation ends', (
    tester,
  ) async {
    final store = await storeFor(profile(thinking: true));
    store.streaming = true;
    await tester.pumpWidget(page(store));
    expect(thinkingSemantics(tester).properties.enabled, isFalse);
    await tester.tap(find.text('深度思考'));
    await tester.pumpAndSettle();
    expect(store.models.active!.thinkingEnabled, isTrue);

    store.streaming = false;
    store.changed();
    await tester.pump();
    expect(thinkingSemantics(tester).properties.enabled, isTrue);
    await tester.tap(find.text('深度思考'));
    await tester.pumpAndSettle();
    expect(store.models.active!.thinkingEnabled, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a failed save preserves the active preference and can be retried',
    (tester) async {
      final preferences = ThinkingPreferences();
      SharedPreferencesStorePlatform.instance = preferences;
      final store = await storeFor(profile(thinking: true));
      final prefs = await SharedPreferences.getInstance();
      final before = jsonDecode(prefs.getString('skivu.models.v1')!);
      await tester.pumpWidget(page(store));
      preferences.failNextWrite = true;

      await tester.tap(find.text('深度思考'));
      await tester.pumpAndSettle();
      expect(store.models.active!.thinkingEnabled, isTrue);
      expect(jsonDecode(prefs.getString('skivu.models.v1')!), before);
      expect(find.text('思考设置未保存，请重试'), findsOneWidget);
      expect(thinkingSemantics(tester).properties.toggled, isTrue);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('深度思考'));
      await tester.pumpAndSettle();
      expect(store.models.active!.thinkingEnabled, isFalse);
    },
  );

  testWidgets(
    'selecting a different connection updates the available control',
    (tester) async {
      final store = await storeFor(profile());
      await store.models.save(
        profile(id: 'other', address: 'https://relay.example/v1'),
        'another-widget-fixture',
      );
      await tester.pumpWidget(page(store));
      await store.models.select('other');
      await tester.pumpAndSettle();
      expect(find.byTooltip('当前连接暂未适配思考开关'), findsOneWidget);
      await tester.tap(find.text('深度思考'));
      await tester.pumpAndSettle();
      expect(store.models.active!.thinkingEnabled, isNull);
      expect(
        store.models.connections
            .firstWhere((c) => c.id == 'direct-deepseek')
            .thinkingEnabled,
        isNull,
      );
      expect(tester.takeException(), isNull);
    },
  );
}

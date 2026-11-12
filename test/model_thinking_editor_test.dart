import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:ski/chat_api.dart';
import 'package:ski/model_connection.dart';
import 'package:ski/model_settings.dart';
import 'package:ski/model_settings_page.dart';
import 'package:ski/state.dart';

import 'real_chat_store_test.dart' show MemoryChats, waitForReply;

ModelConnection editorProfile({String model = 'deepseek-flash'}) =>
    ModelConnection(
      id: 'thinking-editor',
      name: '思考设置测试连接',
      provider: '自定义兼容接口',
      protocol: ApiProtocol.chat,
      address: 'https://api.deepseek.com/v1',
      model: model,
      streaming: false,
      thinkingEnabled: false,
    );

Future<void> openEditor(WidgetTester tester, ModelConnection profile) async {
  await tester.runAsync(
    () => modelSettings.save(profile, 'editor-fixture-key'),
  );
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => FilledButton(
            onPressed: () => const ModelSettingsPage().edit(context, profile),
            child: const Text('编辑测试连接'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('编辑测试连接'));
  await tester.pumpAndSettle();
}

Finder thinkingField() => find.byWidgetPredicate(
  (widget) =>
      widget is DropdownButtonFormField<String> &&
      (widget.key as ValueKey?)?.value.toString().startsWith(
            'thinking-mode-',
          ) ==
          true,
);

class PausedThinkingPreferences extends InMemorySharedPreferencesStore {
  PausedThinkingPreferences() : super.empty();
  Completer<void>? nextWrite;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    final gate = nextWrite;
    nextWrite = null;
    if (gate != null) await gate.future;
    return super.setValue(valueType, key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    modelSettings.connections.clear();
    modelSettings.activeId = null;
    demo.streaming = false;
    demo.useAccount = false;
    demo.useBeta = false;
  });
  tearDown(() {
    demo.streaming = false;
    modelSettings.connections.clear();
    modelSettings.activeId = null;
  });

  testWidgets('renaming a connection preserves its disabled thinking setting', (
    tester,
  ) async {
    await openEditor(tester, editorProfile());
    final name = find.widgetWithText(TextFormField, '连接名称');
    await tester.ensureVisible(name);
    await tester.enterText(name, '修改后的连接名称');
    await tester.runAsync(() async {
      await tester.tap(find.text('保存连接'));
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();

    expect(modelSettings.active!.name, '修改后的连接名称');
    expect(modelSettings.active!.thinkingEnabled, isFalse);
    expect(await modelSettings.keyFor('thinking-editor'), 'editor-fixture-key');
    expect(find.text('保存连接'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the editor can restore the provider default and persist null', (
    tester,
  ) async {
    await openEditor(tester, editorProfile());
    await tester.ensureVisible(thinkingField());
    await tester.tap(thinkingField());
    await tester.pumpAndSettle();
    await tester.tap(find.text('跟随服务商').last);
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('保存连接'));
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();

    expect(modelSettings.active!.thinkingEnabled, isNull);
    final restarted = ModelSettings();
    addTearDown(restarted.dispose);
    await restarted.restore();
    expect(restarted.active!.thinkingEnabled, isNull);
    expect(restarted.active!.effectiveThinkingEnabled, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the editor disables thinking changes while a reply is running', (
    tester,
  ) async {
    await openEditor(tester, editorProfile());
    expect(
      tester.widget<DropdownButtonFormField<String>>(thinkingField()).onChanged,
      isNotNull,
    );
    demo.streaming = true;
    demo.changed();
    await tester.pump();
    expect(
      tester.widget<DropdownButtonFormField<String>>(thinkingField()).onChanged,
      isNull,
    );
    expect(modelSettings.active!.thinkingEnabled, isFalse);

    demo.streaming = false;
    demo.changed();
    await tester.pump();
    expect(
      tester.widget<DropdownButtonFormField<String>>(thinkingField()).onChanged,
      isNotNull,
    );
    await tester.tap(find.byTooltip('关闭配置'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('the editor disables the control for an unsupported model', (
    tester,
  ) async {
    await openEditor(tester, editorProfile(model: 'unknown-model'));
    expect(
      tester.widget<DropdownButtonFormField<String>>(thinkingField()).onChanged,
      isNull,
    );
    expect(find.text('当前连接暂未适配思考开关'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭配置'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  test(
    'pending thinking persistence blocks send, confirmation and regeneration before any request',
    () async {
      final preferences = PausedThinkingPreferences();
      SharedPreferencesStorePlatform.instance = preferences;
      final models = ModelSettings();
      addTearDown(models.dispose);
      await models.save(editorProfile(), 'pending-fixture-key');
      var requests = 0;
      final store = DemoStore(
        settings: models,
        storage: MemoryChats(),
        api: ChatApi(
          clientFactory: () => MockClient((request) async {
            requests++;
            return http.Response(
              '{"choices":[{"message":{"content":"fixture answer"},"finish_reason":"stop"}]}',
              200,
              headers: {'content-type': 'application/json'},
            );
          }),
        ),
      );
      addTearDown(store.dispose);
      await store.restore();
      store.messages.addAll([
        Message(true, 'previous question'),
        Message(false, 'previous answer'),
      ]);
      final previousIds = store.messages.map((message) => message.id).toList();
      final gate = Completer<void>();
      preferences.nextWrite = gate;
      final update = models.setThinkingEnabled('thinking-editor', true);
      addTearDown(() async {
        if (!gate.isCompleted) gate.complete();
        await update;
      });
      expect(store.thinkingUpdatePending, isTrue);

      expect(store.send('must wait'), isFalse);
      expect(store.lastError, '正在保存思考设置，请稍候');
      store.regenerate();
      expect(store.messages.map((message) => message.id), previousIds);
      final queued = Message(true, 'queued question')..status = 'queued';
      store.messages.add(queued);
      expect(store.confirmPending(), isFalse);
      expect(queued.status, 'queued');
      expect(store.streaming, isFalse);
      await Future<void>.delayed(Duration.zero);
      expect(requests, 0);
      expect(store.thinkingUpdatePending, isTrue);

      gate.complete();
      await update;
      expect(store.thinkingUpdatePending, isFalse);
      expect(store.confirmPending(), isTrue);
      await waitForReply(store);
      expect(requests, 1);
      expect(queued.status, 'complete');
    },
  );
}

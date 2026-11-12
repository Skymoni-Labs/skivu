import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:ski/chat.dart';
import 'package:ski/chat_controls.dart';
import 'package:ski/model_connection.dart';
import 'package:ski/model_settings.dart';
import 'package:ski/relay_account.dart';
import 'package:ski/state.dart';

import 'preview_fixture.dart';

class ParameterPreferences extends InMemorySharedPreferencesStore {
  ParameterPreferences() : super.empty();
  final modelWrites = <Map<String, dynamic>>[];

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key.endsWith('skivu.models.v1')) {
      modelWrites.add(Map<String, dynamic>.from(jsonDecode(value as String)));
    }
    return super.setValue(valueType, key, value);
  }
}

class ParameterSecureStorage extends FlutterSecureStoragePlatform {
  final values = <String, String>{};
  int calls = 0;

  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) async {
    calls++;
    return values[key];
  }

  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async {
    calls++;
    values[key] = value;
  }

  @override
  Future<void> delete({
    required String key,
    required Map<String, String> options,
  }) async {
    calls++;
    values.remove(key);
  }

  @override
  Future<bool> containsKey({
    required String key,
    required Map<String, String> options,
  }) async {
    calls++;
    return values.containsKey(key);
  }

  @override
  Future<Map<String, String>> readAll({
    required Map<String, String> options,
  }) async {
    calls++;
    return Map.of(values);
  }

  @override
  Future<void> deleteAll({required Map<String, String> options}) async {
    calls++;
    values.clear();
  }
}

ModelConnection parameterProfile({
  String id = 'parameters-a',
  String address = 'https://api.deepseek.com/v1',
  bool? thinking,
}) => ModelConnection(
  id: id,
  name: id,
  provider: '自定义兼容接口',
  protocol: ApiProtocol.chat,
  address: address,
  model: 'deepseek-flash',
  maxOutput: 100,
  streaming: true,
  thinkingEnabled: thinking,
);

Finder thinkingField() => find.byWidgetPredicate(
  (widget) =>
      widget is DropdownButtonFormField<String> &&
      (widget.key as ValueKey?)?.value.toString().startsWith(
            'chat-thinking-mode-',
          ) ==
          true,
);

Future<void> installProfile(
  WidgetTester tester,
  ModelConnection profile,
) async {
  await tester.runAsync(
    () => modelSettings.save(profile, 'parameters-fixture-key'),
  );
}

Future<void> openParameters(
  WidgetTester tester, {
  bool realChat = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: realChat
            ? ChatPage(openWorkspace: () {}, openCall: () {})
            : Builder(
                builder: (context) => FilledButton(
                  onPressed: () => showChatControls(context),
                  child: const Text('打开对话参数'),
                ),
              ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (realChat) {
    expect(find.byKey(const ValueKey('chat-thinking-toggle')), findsNothing);
    expect(find.text('深度思考'), findsNothing);
    await tester.tap(find.byTooltip('对话设置'));
  } else {
    await tester.tap(find.text('打开对话参数'));
  }
  await tester.pumpAndSettle();
  expect(find.text('对话设置'), findsOneWidget);
}

Future<void> chooseThinking(WidgetTester tester, String label) async {
  await tester.ensureVisible(thinkingField());
  await tester.tap(thinkingField());
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

Future<void> saveParameters(WidgetTester tester) async {
  final save = find.text('保存对话参数');
  await tester.ensureVisible(save);
  await tester.runAsync(() async {
    await tester.tap(save);
    for (var i = 0; i < 100 && modelSettings.thinkingUpdatePending; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(modelSettings.thinkingUpdatePending, isFalse);
  });
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ParameterPreferences preferences;
  late ParameterSecureStorage secure;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    preferences = ParameterPreferences();
    SharedPreferencesStorePlatform.instance = preferences;
    secure = ParameterSecureStorage();
    FlutterSecureStoragePlatform.instance = secure;
    modelSettings.connections.clear();
    modelSettings.activeId = null;
    demo.streaming = false;
    demo.useAccount = false;
    demo.useBeta = false;
    relayAccount.expiresAt = null;
    relayAccount.user = null;
    relayAccount.models.clear();
    seedPreviewConversation();
  });

  tearDown(() {
    demo.streaming = false;
    demo.useAccount = false;
    demo.useBeta = false;
    relayAccount.expiresAt = null;
    relayAccount.user = null;
    relayAccount.models.clear();
    modelSettings.connections.clear();
    modelSettings.activeId = null;
  });

  for (final value in [false, true, null]) {
    testWidgets(
      'parameters save thinking $value together with generation fields without reading keys',
      (tester) async {
        tester.view.physicalSize = const Size(420, 1100);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await installProfile(
          tester,
          parameterProfile(thinking: value == null ? false : null),
        );
        final beforeSecure = Map.of(secure.values), beforeCalls = secure.calls;
        final credentials = modelSettings.active!.credentialId;
        final beforeWrites = preferences.modelWrites.length;
        await openParameters(tester);
        final output = find.widgetWithText(TextFormField, '最大输出 Token');
        await tester.ensureVisible(output);
        await tester.enterText(output, '321');
        final streaming = find.widgetWithText(SwitchListTile, '流式显示回复');
        await tester.ensureVisible(streaming);
        await tester.tap(streaming);
        await tester.pumpAndSettle();
        await chooseThinking(
          tester,
          value == null
              ? '跟随服务商'
              : value
              ? '开启'
              : '关闭',
        );
        await saveParameters(tester);
        expect(find.text('保存对话参数'), findsNothing);
        expect(modelSettings.active!.thinkingEnabled, value);
        expect(modelSettings.active!.maxOutput, 321);
        expect(modelSettings.active!.streaming, isFalse);
        expect(modelSettings.active!.credentialId, credentials);
        expect(secure.calls, beforeCalls);
        expect(secure.values, beforeSecure);
        expect(preferences.modelWrites.length, beforeWrites + 1);
        final saved =
            (preferences.modelWrites.last['connections'] as List).single as Map;
        expect(saved['thinkingEnabled'], value);
        expect(saved['maxOutput'], 321);
        expect(saved['streaming'], isFalse);
        final restarted = ModelSettings();
        addTearDown(restarted.dispose);
        await tester.runAsync(restarted.restore);
        expect(restarted.active!.thinkingEnabled, value);
        expect(restarted.active!.maxOutput, 321);
        expect(restarted.active!.streaming, isFalse);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('unsupported connections expose a disabled thinking field', (
    tester,
  ) async {
    await installProfile(
      tester,
      parameterProfile(address: 'https://relay.example/v1'),
    );
    await openParameters(tester);
    await tester.ensureVisible(thinkingField());
    expect(
      tester.widget<DropdownButtonFormField<String>>(thinkingField()).onChanged,
      isNull,
    );
    expect(find.text('当前连接暂未适配思考开关'), findsOneWidget);
    expect(modelSettings.active!.thinkingEnabled, isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a running reply disables parameter thinking changes', (
    tester,
  ) async {
    await installProfile(tester, parameterProfile());
    await openParameters(tester);
    expect(
      tester.widget<DropdownButtonFormField<String>>(thinkingField()).onChanged,
      isNotNull,
    );
    await chooseThinking(tester, '关闭');
    final beforeWrites = preferences.modelWrites.length;
    demo.streaming = true;
    demo.changed();
    await tester.pump();
    expect(
      tester.widget<DropdownButtonFormField<String>>(thinkingField()).onChanged,
      isNull,
    );
    await saveParameters(tester);
    expect(find.text('保存对话参数'), findsOneWidget);
    expect(preferences.modelWrites.length, beforeWrites);
    expect(modelSettings.active!.thinkingEnabled, isNull);
    demo.streaming = false;
    demo.changed();
    await tester.pump();
    expect(
      tester.widget<DropdownButtonFormField<String>>(thinkingField()).onChanged,
      isNotNull,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'a captured save callback cannot commit after generation starts',
    (tester) async {
      await installProfile(tester, parameterProfile());
      await openParameters(tester);
      await chooseThinking(tester, '关闭');
      final saveButton = find.widgetWithText(FilledButton, '保存对话参数');
      final queuedSave = tester.widget<FilledButton>(saveButton).onPressed!;
      final beforeWrites = preferences.modelWrites.length;
      demo.streaming = true;
      demo.changed();
      await tester.runAsync(() async {
        queuedSave();
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(saveButton).onPressed, isNull);
      expect(preferences.modelWrites.length, beforeWrites);
      expect(modelSettings.active!.thinkingEnabled, isNull);
      expect(modelSettings.thinkingUpdatePending, isFalse);
      expect(find.text('保存对话参数'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'changing direct connections while parameters are open never saves the old draft',
    (tester) async {
      await installProfile(tester, parameterProfile());
      await installProfile(
        tester,
        parameterProfile(id: 'parameters-b', thinking: true),
      );
      await openParameters(tester);
      await chooseThinking(tester, '关闭');
      await tester.runAsync(() => modelSettings.select('parameters-b'));
      final beforeWrites = preferences.modelWrites.length;
      await saveParameters(tester);
      expect(find.text('模型连接已变化，请重新打开对话参数'), findsOneWidget);
      expect(modelSettings.activeId, 'parameters-b');
      expect(modelSettings.active!.thinkingEnabled, isTrue);
      expect(
        modelSettings.connections
            .firstWhere((c) => c.id == 'parameters-a')
            .thinkingEnabled,
        isNull,
      );
      expect(preferences.modelWrites.length, beforeWrites);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'leaving account routing while parameters are open never writes a direct profile',
    (tester) async {
      await installProfile(tester, parameterProfile(thinking: false));
      secure.values['skivu.relay.account.v1'] = jsonEncode({
        'token': 'account-parameter-fixture',
        'expires': DateTime.now()
            .add(const Duration(hours: 1))
            .millisecondsSinceEpoch,
        'model': 'account-fixture-model',
        'limitsVersion': 2,
      });
      await tester.runAsync(relayAccount.restore);
      relayAccount.user = {'id': 7};
      relayAccount.models = ['account-fixture-model'];
      demo.useAccount = true;
      expect(demo.activeConnection?.id, 'skymoni-account');
      await openParameters(tester);
      demo.useAccount = false;
      relayAccount.expiresAt = null;
      demo.changed();
      final beforeWrites = preferences.modelWrites.length;
      final beforeSecure = Map.of(secure.values), beforeCalls = secure.calls;
      await saveParameters(tester);
      expect(find.text('模型连接已变化，请重新打开对话参数'), findsOneWidget);
      expect(modelSettings.connections.length, 1);
      expect(modelSettings.active!.thinkingEnabled, isFalse);
      expect(preferences.modelWrites.length, beforeWrites);
      expect(secure.calls, beforeCalls);
      expect(secure.values, beforeSecure);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'the normal chat settings entry opens thinking parameters without a composer toggle',
    (tester) async {
      tester.view.physicalSize = const Size(420, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await installProfile(tester, parameterProfile());
      await openParameters(tester, realChat: true);
      await tester.ensureVisible(thinkingField());
      expect(find.text('深度思考'), findsOneWidget);
      expect(
        tester
            .widget<DropdownButtonFormField<String>>(thinkingField())
            .onChanged,
        isNotNull,
      );
      expect(find.byKey(const ValueKey('chat-thinking-toggle')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

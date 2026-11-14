import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/speech_settings.dart';
import 'package:ski/speech_settings_page.dart';

const custom = SpeechProfile(
  id: 'saved-custom',
  name: '我的自定义声音',
  provider: SpeechProvider.custom,
  endpoint: 'https://voice.example/tts',
  apiKey: 'fixture-custom-key',
  headers: '{"X-Key":"{key}"}',
  body: '{"input":"{text}"}',
  response: 'base64',
  responsePath: 'data.audio',
  speed: 1.3,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('skivu/voice_call');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    messenger.setMockMethodCallHandler(channel, (_) async => null);
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  Future<SpeechSettings> mount(WidgetTester tester) async {
    final settings = SpeechSettings();
    await settings.save(custom);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SpeechSettingsPage(settings: settings),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return settings;
  }

  testWidgets(
    'visible DeepSeek preset configures two voices without replacing custom service',
    (tester) async {
      final settings = await mount(tester);
      expect(find.text('DeepSeek 语音合成'), findsOneWidget);
      expect(settings.active.id, custom.id);
      await tester.tap(find.text('DeepSeek 语音合成'));
      await tester.pumpAndSettle();
      expect(find.text(deepseekTtsEndpoint), findsOneWidget);
      expect(find.text('模型 ID'), findsNothing);
      expect(find.byType(Slider), findsNothing);
      expect(settings.active.id, custom.id);

      final keyField = find.widgetWithText(TextFormField, 'API Key');
      await tester.scrollUntilVisible(
        keyField,
        240,
        scrollable: find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.enterText(keyField, 'fixture-deepseek-key');
      final voice = find.byKey(const ValueKey('deepseek-voice'));
      await tester.ensureVisible(voice);
      await tester.pumpAndSettle();
      await tester.tap(voice);
      await tester.pumpAndSettle();
      await tester.tap(find.text('暗潮 · 男声').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存并使用'));
      await tester.pumpAndSettle();

      expect(settings.active.provider, SpeechProvider.deepseek);
      expect(settings.active.voice, 'tide');
      expect(settings.active.endpoint, deepseekTtsEndpoint);
      expect(
        settings.profiles.singleWhere((p) => p.id == custom.id).toJson(),
        custom.toJson(),
      );
      final restored = SpeechSettings();
      await restored.restore();
      expect(restored.active.apiKey, 'fixture-deepseek-key');
      expect(restored.active.voice, 'tide');
      expect(
        restored.profiles.singleWhere((p) => p.id == custom.id).toJson(),
        custom.toJson(),
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      settings.dispose();
      restored.dispose();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'opening, cancelling or saving an empty-key preset keeps prior connection intact',
    (tester) async {
      final settings = await mount(tester);
      const secure = FlutterSecureStorage();
      final before = await secure.read(key: SpeechSettings.storageKey);
      await tester.tap(find.text('DeepSeek 语音合成'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存并使用'));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView), const Offset(0, -1200));
      await tester.pumpAndSettle();
      expect(find.text('请填写 DeepSeek API Key'), findsOneWidget);
      expect(settings.active.id, custom.id);
      expect(await secure.read(key: SpeechSettings.storageKey), before);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(settings.active.id, custom.id);
      expect(await secure.read(key: SpeechSettings.storageKey), before);
      expect(find.text('DeepSeek 语音合成'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      settings.dispose();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'DeepSeek editor keeps save reachable at 320px with enlarged text and keyboard in both themes',
    (tester) async {
      tester.view.physicalSize = const Size(320, 740);
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      addTearDown(tester.view.reset);
      for (final brightness in Brightness.values) {
        final settings = SpeechSettings();
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: brightness),
            builder: (c, child) => MediaQuery(
              data: MediaQuery.of(
                c,
              ).copyWith(textScaler: const TextScaler.linear(1.4)),
              child: child!,
            ),
            home: SpeechEditor(
              settings: settings,
              profile: SpeechProfile.deepseek,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.getBottomRight(find.text('保存并使用')).dy, lessThan(480));
        await tester.drag(find.byType(ListView), const Offset(0, -1800));
        await tester.pumpAndSettle();
        expect(find.byType(Slider), findsNothing);
        expect(find.text('模型 ID'), findsNothing);
        expect(find.text('海星 · 女声'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        settings.dispose();
      }
    },
  );
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/services.dart';
import 'package:ski/speech_settings.dart';
import 'package:ski/speech_settings_page.dart';
import 'package:ski/speech_recognition_page.dart';
import 'package:ski/speech_recognition_settings.dart';

void main() {
  testWidgets(
    'recognition configuration keeps save visible above keyboard on narrow enlarged screen',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      tester.view.physicalSize = const Size(320, 740);
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      addTearDown(tester.view.reset);
      const channel = MethodChannel('skivu/voice_call');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (m) async => m.method == 'recognitionStatus'
                ? {
                    'systemAvailable': false,
                    'onDeviceAvailable': false,
                    'microphoneGranted': false,
                  }
                : null,
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final settings = SpeechSettings();
      await settings.saveRecognition(
        const RecognitionProfile(
          provider: RecognitionProvider.custom,
          endpoint: 'https://voice.example/asr',
          silenceMillis: 0,
          timeoutSeconds: 0,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          builder: (c, child) => MediaQuery(
            data: MediaQuery.of(
              c,
            ).copyWith(textScaler: const TextScaler.linear(1.2)),
            child: child!,
          ),
          home: RecognitionSettingsPage(settings: settings),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('保存并使用'), findsOneWidget);
      expect(tester.getBottomRight(find.text('保存并使用')).dy, lessThan(480));
      await tester.drag(find.byType(ListView), const Offset(0, -2000));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      settings.dispose();
    },
  );
  testWidgets(
    'custom voice editor fits narrow enlarged text and keyboard without clipping save',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      tester.view.physicalSize = const Size(320, 740);
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      addTearDown(tester.view.reset);
      final settings = SpeechSettings();
      await tester.pumpWidget(
        MaterialApp(
          builder: (c, child) => MediaQuery(
            data: MediaQuery.of(
              c,
            ).copyWith(textScaler: const TextScaler.linear(1.2)),
            child: child!,
          ),
          home: SpeechEditor(
            settings: settings,
            profile: const SpeechProfile(
              id: 'custom',
              name: '自定义服务',
              provider: SpeechProvider.custom,
              endpoint: 'https://voice.example/tts',
              response: 'base64',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('保存并使用'), findsOneWidget);
      expect(tester.getBottomRight(find.text('保存并使用')).dy, lessThan(740 - 260));
      await tester.drag(find.byType(ListView), const Offset(0, -1800));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      settings.dispose();
    },
  );
}

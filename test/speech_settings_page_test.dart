import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:ski/speech_settings.dart';
import 'package:ski/speech_settings_page.dart';

void main() {
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

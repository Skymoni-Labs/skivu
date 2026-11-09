import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ski/main.dart' as app;
import 'package:ski/speech_input_session.dart';
import 'package:ski/speech_recognition_settings.dart';
import 'package:ski/speech_settings.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native microphone capture reaches selected custom ASR and cleans its temporary audio',
    (tester) async {
      expect(const bool.fromEnvironment('SKIVU_ENGINE_QA'), true);
      await app.main();
      await tester.pumpAndSettle();
      const channel = MethodChannel('skivu/voice_call');
      final status = await channel.invokeMapMethod<String, dynamic>(
        'recognitionStatus',
      );
      expect(status?['microphoneGranted'], true);
      final settings = SpeechSettings();
      await settings.restore();
      final originalRecognition = settings.recognition;
      final received = Completer<Map<String, dynamic>>();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        try {
          final bytes = await request.fold<List<int>>(
            [],
            (a, b) => a..addAll(b),
          );
          final raw = latin1.decode(bytes);
          final start =
              raw.indexOf('\r\n\r\n', raw.indexOf('filename="speech.m4a"')) + 4;
          final end = raw.indexOf('\r\n--', start);
          final audio = bytes.sublist(start, end);
          expect(audio.length, greaterThan(1000));
          expect(latin1.decode(audio.sublist(4, 8)), 'ftyp');
          received.complete({
            'audioBytes': audio.length,
            'sha256': sha256.convert(audio).toString(),
            'transport': 'actual-multipart',
            'serviceReplyIsControlledFixture': true,
          });
          request.response.headers.contentType = ContentType.json;
          request.response.write('{"text":"模拟器录音上传链路验收"}');
          await request.response.close();
        } catch (e, st) {
          received.completeError(e, st);
          await request.response.close();
        }
      });
      final input = SpeechInputSession(settings: settings);
      try {
        await settings.saveRecognition(
          RecognitionProfile(
            provider: RecognitionProvider.custom,
            endpoint: 'http://127.0.0.1:${server.port}/asr',
            silenceMillis: 0,
            model: 'controlled-asr-fixture',
          ),
        );
        await tester.runAsync(() async {
          final pending = input.listen();
          await Future<void>.delayed(const Duration(seconds: 3));
          await input.finish();
          expect(await pending, '模拟器录音上传链路验收');
          final evidence = await received.future;
          binding.reportData = {
            'nativeStatus': status,
            'realAndroidMicrophoneCapture': true,
            ...evidence,
            'textReturnedToInput': true,
            'defaultSystemRecognitionRetained':
                const RecognitionProfile().provider ==
                RecognitionProvider.system,
          };
        });
      } finally {
        input.dispose();
        await settings.saveRecognition(originalRecognition);
        settings.dispose();
        await server.close(force: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/speech_recognition_settings.dart';
import 'package:ski/speech_recognition_upload_io.dart';
import 'package:ski/speech_input_session.dart';
import 'package:ski/speech_settings.dart';
import 'package:ski/voice_call_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('skivu/voice_call');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  Future<void> emit(String method, Map<String, dynamic> args) async {
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
      (_) {},
    );
  }

  setUp(() {
    // These two fixtures deliberately exercise a real local HTTP socket.
    HttpOverrides.global = null;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    FlutterSecureStorage.setMockInitialValues({});
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });
  test(
    'old synthesis configuration restores unchanged with native recognition default',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        SpeechSettings.storageKey: jsonEncode({
          'profiles': [SpeechProfile.system.toJson()],
          'activeId': 'system',
        }),
      });
      final settings = SpeechSettings();
      await settings.restore();
      expect(settings.recognition.provider, RecognitionProvider.system);
      await settings.saveRecognition(
        const RecognitionProfile(
          provider: RecognitionProvider.custom,
          endpoint: 'http://localhost/asr',
          apiKey: 'private',
          transport: 'json',
          responsePath: 'data.text',
        ),
      );
      await settings.save(
        const SpeechProfile(id: 'other', name: 'Other system voice'),
      );
      final restored = SpeechSettings();
      await restored.restore();
      expect(restored.activeId, 'other');
      expect(restored.recognition.apiKey, 'private');
      expect(restored.recognition.responsePath, 'data.text');
      settings.dispose();
      restored.dispose();
    },
  );
  test(
    'native input uses configured language, retains partial and waits for explicit final',
    () async {
      final settings = SpeechSettings();
      await settings.saveRecognition(
        const RecognitionProfile(language: 'en-US', preferOnDevice: true),
      );
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (m) async {
        calls.add(m);
        return m.method == 'listen' ? 'listening' : null;
      });
      final input = SpeechInputSession(settings: settings);
      final pending = input.listen();
      await Future<void>.delayed(Duration.zero);
      expect(calls.first.arguments, containsPair('language', 'en-US'));
      expect(calls.first.arguments, containsPair('preferOnDevice', true));
      await emit('partial', {'text': 'partial only'});
      expect(input.partial, 'partial only');
      await input.finish();
      expect(calls.last.method, 'finishListening');
      await emit('result', {'text': 'actual final'});
      expect(await pending, 'actual final');
      expect(calls.last.method, 'stopListening');
      input.dispose();
      settings.dispose();
    },
  );
  test(
    'second draft cannot replace a live call handler or close its microphone',
    () async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (m) async {
        calls.add(m.method);
        return m.method == 'listen' ? 'listening' : null;
      });
      final call = VoiceCallSession();
      await call.start();
      final input = SpeechInputSession();
      await expectLater(input.listen(), throwsFormatException);
      expect(calls.where((c) => c == 'stopListening'), isEmpty);
      await emit('recognitionError', {'code': 12});
      expect(call.error, contains('不支持此语言'));
      input.dispose();
      await call.end();
      call.dispose();
    },
  );
  test(
    'permission denial and native network errors are specific, never fabricated text',
    () async {
      messenger.setMockMethodCallHandler(
        channel,
        (m) async => m.method == 'listen' ? 'permission_required' : null,
      );
      final first = SpeechInputSession();
      await expectLater(
        first.listen(),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'permission',
            contains('麦克风'),
          ),
        ),
      );
      first.dispose();
      messenger.setMockMethodCallHandler(
        channel,
        (m) async => m.method == 'listen' ? 'listening' : null,
      );
      final next = SpeechInputSession();
      final pending = next.listen();
      await Future<void>.delayed(Duration.zero);
      await emit('recognitionError', {'code': 2});
      await expectLater(
        pending,
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'network',
            contains('网络'),
          ),
        ),
      );
      next.dispose();
    },
  );
  test(
    'custom multipart streams complete recording and decodes long transcript',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final file = File(
        '${Directory.systemTemp.path}/skivu-asr-${DateTime.now().microsecondsSinceEpoch}.m4a',
      );
      final audio = List<int>.generate(1024 * 1024 + 13, (i) => i % 251);
      await file.writeAsBytes(audio);
      final received = Completer<void>();
      final transcript = '完整识别文字'.padRight(18000, '字');
      server.listen((request) async {
        try {
          expect(
            request.headers.value('authorization'),
            'Bearer local-test-only',
          );
          final bytes = await request.fold<List<int>>(
            [],
            (a, b) => a..addAll(b),
          );
          expect(bytes.length, greaterThan(audio.length));
          final text = latin1.decode(bytes);
          expect(text, contains('speech.m4a'));
          expect(text, contains('audio/mp4'));
          expect(text, contains('name="language"\r\n\r\nzh'));
          final start =
              text.indexOf('\r\n\r\n', text.indexOf('filename="speech.m4a"')) +
              4;
          expect(bytes.sublist(start, start + audio.length), audio);
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'text': transcript}));
          await request.response.close();
          received.complete();
        } catch (e, st) {
          received.completeError(e, st);
          await request.response.close();
        }
      });
      try {
        final value = await RecognitionUpload().transcribe(
          RecognitionProfile(
            provider: RecognitionProvider.openai,
            endpoint: 'http://127.0.0.1:${server.port}/transcribe',
            apiKey: 'local-test-only',
            model: 'test-model',
          ),
          file.path,
        );
        expect(value, transcript);
        await received.future;
      } finally {
        await server.close(force: true);
        await file.delete();
      }
    },
  );
  test(
    'cancel settles a pending microphone permission request and prevents late capture',
    () async {
      final permission = Completer<String>();
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (m) async {
        calls.add(m.method);
        if (m.method == 'listen') return permission.future;
        if (m.method == 'stopListening' && !permission.isCompleted)
          permission.complete('permission_required');
        return null;
      });
      final input = SpeechInputSession();
      final pending = input.listen();
      await Future<void>.delayed(Duration.zero);
      input.cancel();
      await expectLater(
        pending,
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'canceled',
            contains('已取消'),
          ),
        ),
      );
      expect(calls.where((m) => m == 'listen'), hasLength(1));
      expect(calls, contains('stopListening'));
      input.dispose();
    },
  );
  test(
    'custom JSON response path and capture cancellation use selected service only',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final file = File(
        '${Directory.systemTemp.path}/skivu-asr-json-${DateTime.now().microsecondsSinceEpoch}.m4a',
      );
      await file.writeAsBytes([0, 1, 2, 3]);
      server.listen((request) async {
        final data = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        expect(data['audio'], base64Encode([0, 1, 2, 3]));
        request.response.write('{"data":{"text":"自定义结果"}}');
        await request.response.close();
      });
      final settings = SpeechSettings();
      await settings.saveRecognition(
        RecognitionProfile(
          provider: RecognitionProvider.custom,
          endpoint: 'http://127.0.0.1:${server.port}/asr',
          transport: 'json',
          audioField: 'audio',
          responsePath: 'data.text',
        ),
      );
      final methods = <String>[];
      messenger.setMockMethodCallHandler(channel, (m) async {
        methods.add(m.method);
        return m.method == 'record' ? 'recording' : null;
      });
      final input = SpeechInputSession(settings: settings);
      try {
        final pending = input.listen();
        await Future<void>.delayed(Duration.zero);
        await emit('recorded', {'path': file.path});
        expect(await pending, '自定义结果');
        expect(methods, contains('record'));
        expect(methods, isNot(contains('listen')));
        expect(methods, contains('discardRecording'));
        final cancelled = input.listen();
        await Future<void>.delayed(Duration.zero);
        input.cancel();
        await expectLater(cancelled, throwsFormatException);
      } finally {
        input.dispose();
        settings.dispose();
        await server.close(force: true);
        await file.delete();
      }
    },
  );
}

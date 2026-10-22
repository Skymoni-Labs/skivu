import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ski/speech_api.dart';
import 'package:ski/speech_settings.dart';

const profile = SpeechProfile(
  id: 'test',
  name: '测试声音',
  provider: SpeechProvider.openai,
  endpoint: 'https://voice.example/v1/audio/speech',
  apiKey: 'fixture-key',
  model: 'tts-fixture',
  voice: 'calm',
);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('custom Hex audio is decoded and malformed Hex is rejected', () async {
    const custom = SpeechProfile(
      id: 'hex',
      name: 'Hex',
      provider: SpeechProvider.custom,
      endpoint: 'https://voice.example/tts',
      response: 'hex',
      responsePath: 'data.audio',
    );
    final api = SpeechApi(
      clientFactory: () => MockClient(
        (_) async => http.Response('{"data":{"audio":"524946460102"}}', 200),
      ),
    );
    expect(await api.synthesize(custom, '测试'), [82, 73, 70, 70, 1, 2]);
    final invalid = SpeechApi(
      clientFactory: () => MockClient(
        (_) async => http.Response('{"data":{"audio":"not-hex"}}', 200),
      ),
    );
    await expectLater(
      invalid.synthesize(custom, '测试'),
      throwsA(isA<SpeechFailure>()),
    );
  });
  test(
    'OpenAI compatibility builds a full endpoint request and never follows redirects',
    () async {
      final api = SpeechApi(
        clientFactory: () => MockClient((request) async {
          expect(request.url.toString(), profile.endpoint);
          expect(request.followRedirects, isFalse);
          expect(request.headers['Authorization'], 'Bearer fixture-key');
          expect(jsonDecode(request.body), {
            'model': 'tts-fixture',
            'input': '他说："你好"\n下一句',
            'voice': 'calm',
            'speed': 1.0,
            'response_format': 'mp3',
          });
          return http.Response.bytes([73, 68, 51, 0, 1, 2], 200);
        }),
      );
      expect(await api.synthesize(profile, '他说："你好"\n下一句'), [
        73,
        68,
        51,
        0,
        1,
        2,
      ]);
    },
  );
  test(
    'ElevenLabs voice and Azure SSML are encoded without text injection',
    () {
      final eleven = SpeechProfile(
        id: 'eleven',
        name: 'Eleven',
        provider: SpeechProvider.elevenlabs,
        endpoint: 'https://api.elevenlabs.io/v1/text-to-speech/{voice}',
        apiKey: 'fixture-eleven',
        voice: 'voice id',
        model: 'eleven_multilingual_v2',
      );
      final request = buildSpeechRequest(eleven, 'Hello');
      expect(request.url.pathSegments.last, 'voice id');
      expect(request.headers['xi-api-key'], 'fixture-eleven');
      expect(jsonDecode(request.body)['model_id'], 'eleven_multilingual_v2');
      const azure = SpeechProfile(
        id: 'azure',
        name: 'Azure',
        provider: SpeechProvider.azure,
        endpoint:
            'https://eastasia.tts.speech.microsoft.com/cognitiveservices/v1',
        voice: 'zh-CN-XiaoxiaoNeural',
        speed: 1.2,
      );
      final ssml = buildSpeechRequest(azure, '<break/> & "你好"');
      expect(ssml.body, contains('&lt;break/&gt; &amp; &quot;你好&quot;'));
      expect(ssml.body, contains('rate="+20%"'));
    },
  );
  test(
    'custom JSON templates preserve quoted text, numeric speed and Base64 audio',
    () async {
      const custom = SpeechProfile(
        id: 'custom',
        name: 'Custom',
        provider: SpeechProvider.custom,
        endpoint: 'http://127.0.0.1:1234/tts',
        apiKey: 'fixture-custom',
        headers: '{"X-Key":"{key}"}',
        body: '{"input":{"text":"{text}"},"rate":"{speed}"}',
        response: 'base64',
        responsePath: 'data.0.audio',
      );
      final api = SpeechApi(
        clientFactory: () => MockClient((request) async {
          final body = jsonDecode(request.body);
          expect(body['input']['text'], '"引号"\n与换行');
          expect(body['rate'], 1.0);
          expect(request.headers['X-Key'], 'fixture-custom');
          return http.Response(
            jsonEncode({
              'data': [
                {
                  'audio': base64Encode([82, 73, 70, 70, 1, 2]),
                },
              ],
            }),
            200,
          );
        }),
      );
      expect(await api.synthesize(custom, '"引号"\n与换行'), [82, 73, 70, 70, 1, 2]);
    },
  );
  test('returned audio URL does not inherit API authorization', () async {
    const custom = SpeechProfile(
      id: 'url',
      name: 'URL',
      provider: SpeechProvider.custom,
      endpoint: 'https://voice.example/tts',
      apiKey: 'secret-fixture',
      headers: '{"Authorization":"Bearer {key}"}',
      response: 'url',
      responsePath: 'data.url',
    );
    var calls = 0;
    final api = SpeechApi(
      clientFactory: () => MockClient((request) async {
        calls++;
        if (calls == 1)
          return http.Response(
            '{"data":{"url":"https://audio.example/a.mp3"}}',
            200,
          );
        expect(request.headers.containsKey('Authorization'), isFalse);
        expect(request.followRedirects, isFalse);
        return http.Response.bytes([73, 68, 51, 1], 200);
      }),
    );
    expect(await api.synthesize(custom, '你好'), [73, 68, 51, 1]);
    expect(calls, 2);
  });
  test(
    'authentication errors never leak provider bodies or keys and cancellation rejects late audio',
    () async {
      final denied = SpeechApi(
        clientFactory: () =>
            MockClient((_) async => http.Response('secret-fixture-body', 401)),
      );
      await expectLater(
        denied.synthesize(profile, 'hello'),
        throwsA(
          isA<SpeechFailure>().having(
            (e) => e.message,
            'message',
            allOf(contains('鉴权失败'), isNot(contains('secret'))),
          ),
        ),
      );
      final pending = Completer<http.Response>();
      final api = SpeechApi(
        clientFactory: () => MockClient((_) => pending.future),
      );
      final result = api.synthesize(profile, 'hello');
      await Future<void>.delayed(Duration.zero);
      api.cancel();
      pending.complete(http.Response.bytes([73, 68, 51, 1], 200));
      await expectLater(result, throwsA(isA<SpeechFailure>()));
    },
  );
  test(
    'voice keys, headers and templates persist securely and deletion returns to system',
    () async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      final settings = SpeechSettings();
      await settings.save(profile);
      expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
      final restored = SpeechSettings();
      await restored.restore();
      expect(restored.active.apiKey, 'fixture-key');
      expect(restored.active.voice, 'calm');
      await restored.remove(profile.id);
      expect(restored.active.id, 'system');
      expect(
        await const FlutterSecureStorage().read(key: SpeechSettings.storageKey),
        isNot(contains('fixture-key')),
      );
      settings.dispose();
      restored.dispose();
    },
  );
}

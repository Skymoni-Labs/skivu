import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
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

const _deepseekProfile = SpeechProfile(
  id: 'deepseek-fixture',
  name: 'DeepSeek fixture',
  provider: SpeechProvider.deepseek,
  endpoint: 'https://voice.example/v1/tools/tts',
  apiKey: 'fixture-key',
  voice: 'stella',
);

Uint8List _waveChunk(String name, List<int> payload) {
  final bytes = Uint8List(8 + payload.length + payload.length % 2);
  bytes.setRange(0, 4, ascii.encode(name));
  ByteData.sublistView(bytes).setUint32(4, payload.length, Endian.little);
  bytes.setRange(8, 8 + payload.length, payload);
  return bytes;
}

({Uint8List bytes, int dataSizeOffset}) _waveFixture({bool metadata = false}) {
  final format = Uint8List(16);
  final fields = ByteData.sublistView(format);
  fields.setUint16(0, 1, Endian.little); // PCM.
  fields.setUint16(2, 1, Endian.little);
  fields.setUint32(4, 24000, Endian.little);
  fields.setUint32(8, 48000, Endian.little);
  fields.setUint16(12, 2, Endian.little);
  fields.setUint16(14, 16, Endian.little);
  final chunks = BytesBuilder();
  if (metadata) chunks.add(_waveChunk('JUNK', [1, 2, 3]));
  chunks.add(_waveChunk('fmt ', format));
  if (metadata) chunks.add(_waveChunk('LIST', [4, 5]));
  final dataSizeOffset = 12 + chunks.length + 4;
  chunks.add(_waveChunk('data', [0, 0, 1, 0, 2, 0, 3, 0]));
  final body = chunks.takeBytes();
  final bytes = Uint8List(12 + body.length);
  bytes.setRange(0, 4, ascii.encode('RIFF'));
  ByteData.sublistView(bytes).setUint32(4, bytes.length - 8, Endian.little);
  bytes.setRange(8, 12, ascii.encode('WAVE'));
  bytes.setRange(12, bytes.length, body);
  return (bytes: bytes, dataSizeOffset: dataSizeOffset);
}

class _StreamedAudioClient extends http.BaseClient {
  _StreamedAudioClient(this.body, this.contentLength);
  final Stream<List<int>> body;
  final int? contentLength;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(
        body,
        200,
        contentLength: contentLength,
        headers: {'content-type': 'audio/wav'},
      );
}

Future<Uint8List> _synthesizeWave(
  Uint8List audio, {
  SpeechProfile selected = _deepseekProfile,
  int? contentLength,
  Stream<List<int>>? body,
}) {
  final api = SpeechApi(
    clientFactory: () => _StreamedAudioClient(
      body ??
          Stream.fromIterable([
            audio.sublist(0, 5),
            audio.sublist(5, 41),
            audio.sublist(41),
          ]),
      contentLength,
    ),
  );
  addTearDown(api.cancel);
  return api.synthesize(selected, '语音格式测试');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('DeepSeek buffered streaming WAV preparation', () {
    for (final placeholder in [0xffffffff, 0x7fffffff, 0]) {
      for (final fields in ['RIFF', 'data', 'both']) {
        test('normalizes $fields length placeholder $placeholder', () async {
          final fixture = _waveFixture(metadata: true);
          final received = Uint8List.fromList(fixture.bytes);
          final lengths = ByteData.sublistView(received);
          if (fields != 'data')
            lengths.setUint32(4, placeholder, Endian.little);
          if (fields != 'RIFF') {
            lengths.setUint32(
              fixture.dataSizeOffset,
              placeholder,
              Endian.little,
            );
          }
          final original = Uint8List.fromList(received);

          // Includes an odd-sized padded JUNK chunk before fmt and a LIST chunk
          // before data: its length field is deliberately not at offset 40.
          expect(fixture.dataSizeOffset, 62);
          final playable = await _synthesizeWave(received);
          expect(playable, orderedEquals(fixture.bytes));
          expect(received, orderedEquals(original));
        });
      }
    }

    test('preserves finite WAV and metadata bytes without rewriting', () async {
      final fixture = _waveFixture(metadata: true);
      expect(
        await _synthesizeWave(
          fixture.bytes,
          contentLength: fixture.bytes.length,
        ),
        orderedEquals(fixture.bytes),
      );
    });

    test('does not rewrite custom provider streaming WAV headers', () async {
      final fixture = _waveFixture();
      final lengths = ByteData.sublistView(fixture.bytes);
      lengths.setUint32(4, 0xffffffff, Endian.little);
      lengths.setUint32(fixture.dataSizeOffset, 0xffffffff, Endian.little);
      const custom = SpeechProfile(
        id: 'custom-wave',
        name: 'Custom wave',
        provider: SpeechProvider.custom,
        endpoint: 'https://voice.example/tts',
      );
      expect(
        await _synthesizeWave(fixture.bytes, selected: custom),
        orderedEquals(fixture.bytes),
      );
    });

    test('rejects unknown data that ends between PCM samples', () async {
      final fixture = _waveFixture(metadata: true);
      final truncated = Uint8List.fromList(
        fixture.bytes.sublist(0, fixture.bytes.length - 1),
      );
      final lengths = ByteData.sublistView(truncated);
      lengths.setUint32(4, 0xffffffff, Endian.little);
      lengths.setUint32(fixture.dataSizeOffset, 0xffffffff, Endian.little);
      await expectLater(
        _synthesizeWave(truncated),
        throwsA(isA<SpeechFailure>()),
      );
    });

    test(
      'rejects Content-Length mismatch before normalizing headers',
      () async {
        final fixture = _waveFixture();
        final lengths = ByteData.sublistView(fixture.bytes);
        lengths.setUint32(4, 0xffffffff, Endian.little);
        lengths.setUint32(fixture.dataSizeOffset, 0xffffffff, Endian.little);
        await expectLater(
          _synthesizeWave(
            fixture.bytes,
            contentLength: fixture.bytes.length + 2,
          ),
          throwsA(isA<SpeechFailure>()),
        );
      },
    );

    test(
      'rejects stream errors even after a valid aligned WAV arrives',
      () async {
        final fixture = _waveFixture();
        final lengths = ByteData.sublistView(fixture.bytes);
        lengths.setUint32(4, 0xffffffff, Endian.little);
        lengths.setUint32(fixture.dataSizeOffset, 0xffffffff, Endian.little);
        Stream<List<int>> brokenBody() async* {
          yield fixture.bytes;
          throw http.ClientException('fixture stream failure');
        }

        await expectLater(
          _synthesizeWave(fixture.bytes, body: brokenBody()),
          throwsA(isA<SpeechFailure>()),
        );
      },
    );
  });
  test(
    'synthesis preserves text beyond 10000 and audio beyond 10 MiB',
    () async {
      final text = '完整语音🙂' * 4000;
      final audio = List<int>.filled(10 * 1024 * 1024 + 73, 1);
      audio.setRange(0, 3, [73, 68, 51]);
      final api = SpeechApi(
        clientFactory: () => MockClient((request) async {
          expect(jsonDecode(request.body)['input'], text);
          return http.Response.bytes(audio, 200);
        }),
      );
      expect(await api.synthesize(profile, text), orderedEquals(audio));
    },
  );
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

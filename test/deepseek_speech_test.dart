import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ski/speech_api.dart';
import 'package:ski/speech_settings.dart';

const _key = 'fixture-deepseek-api-key';
const _custom = SpeechProfile(
  id: 'existing-custom-tts',
  name: '原有自定义语音',
  provider: SpeechProvider.custom,
  endpoint: 'https://voice.example/custom',
  apiKey: 'fixture-existing-key',
  model: 'existing-model',
  voice: 'existing-voice',
  speed: 1.2,
  headers: '{"X-Api-Key":"{key}","X-Existing":"keep"}',
  body: '{"content":"{text}","rate":"{speed}","model":"{model}"}',
  response: 'base64',
  responsePath: 'result.audio',
  instructions: 'existing instructions',
  timeoutSeconds: 17,
);

SpeechProfile _deepseek({String voice = 'stella', String key = _key}) =>
    SpeechProfile.fromJson({
      ...SpeechProfile.deepseek.toJson(),
      'apiKey': key,
      'voice': voice,
    });

Uint8List _littleEndian32(int value) =>
    (ByteData(4)..setUint32(0, value, Endian.little)).buffer.asUint8List();

Uint8List _chunk(String id, List<int> content) =>
    (BytesBuilder()
          ..add(ascii.encode(id))
          ..add(_littleEndian32(content.length))
          ..add(content)
          ..add(content.length.isOdd ? [0] : []))
        .takeBytes();

Uint8List _waveWithChunks(List<Uint8List> chunks) {
  final body = (BytesBuilder()..add(ascii.encode('WAVE')));
  for (final chunk in chunks) {
    body.add(chunk);
  }
  final payload = body.takeBytes();
  return (BytesBuilder()
        ..add(ascii.encode('RIFF'))
        ..add(_littleEndian32(payload.length))
        ..add(payload))
      .takeBytes();
}

Uint8List _pcmFormat() =>
    (ByteData(16)
          ..setUint16(0, 1, Endian.little)
          ..setUint16(2, 1, Endian.little)
          ..setUint32(4, 24000, Endian.little)
          ..setUint32(8, 48000, Endian.little)
          ..setUint16(12, 2, Endian.little)
          ..setUint16(14, 16, Endian.little))
        .buffer
        .asUint8List();

Uint8List _wave({bool withMetadata = false}) => _waveWithChunks([
  if (withMetadata) _chunk('JUNK', [1, 2, 3]),
  _chunk('fmt ', _pcmFormat()),
  _chunk('data', [0, 0, 1, 0]),
]);

Uint8List _withSizeAt(Uint8List audio, int offset, int size) {
  final copy = Uint8List.fromList(audio);
  ByteData.sublistView(copy).setUint32(offset, size, Endian.little);
  return copy;
}

Matcher _safeFailure({String? containing}) => isA<SpeechFailure>().having(
  (error) => error.message,
  'message',
  allOf([
    isNot(contains(_key)),
    isNot(contains('private-provider-detail')),
    if (containing != null) contains(containing),
  ]),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DeepSeek selectable preset and secure settings', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
    });

    test('preset is available without selecting or persisting it', () async {
      final settings = SpeechSettings();
      addTearDown(settings.dispose);
      final preset = settings.availableProfiles.singleWhere(
        (profile) => profile.provider == SpeechProvider.deepseek,
      );

      expect(preset.id, 'builtin-deepseek-tts');
      expect(preset.endpoint, 'https://api.deepseek.com/v1/tools/tts');
      expect(preset.voice, 'stella');
      expect(preset.apiKey, isEmpty);
      expect(preset.model, isEmpty);
      expect(preset.validate, returnsNormally);
      expect(settings.profiles.map((profile) => profile.id), ['system']);
      expect(settings.activeId, 'system');
      expect(settings.active.provider, SpeechProvider.system);
      expect(
        await const FlutterSecureStorage().read(key: SpeechSettings.storageKey),
        isNull,
      );
      expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
    });

    test(
      'reading preset preserves existing custom profile, selection and v1 data',
      () async {
        final settings = SpeechSettings();
        addTearDown(settings.dispose);
        await settings.save(_custom);
        final secure = const FlutterSecureStorage();
        final before = await secure.read(key: SpeechSettings.storageKey);

        final restored = SpeechSettings();
        addTearDown(restored.dispose);
        await restored.restore();
        for (var i = 0; i < 3; i++) {
          expect(
            restored.availableProfiles.where(
              (profile) => profile.provider == SpeechProvider.deepseek,
            ),
            hasLength(1),
          );
        }

        expect(SpeechSettings.storageKey, 'skivu.speech.v1');
        expect(restored.activeId, _custom.id);
        expect(restored.active.toJson(), _custom.toJson());
        expect(restored.profiles.map((profile) => profile.id), [
          'system',
          _custom.id,
        ]);
        expect(await secure.read(key: SpeechSettings.storageKey), before);
        expect(
          (jsonDecode(before!) as Map)['profiles'],
          isNot(contains(containsPair('provider', 'deepseek'))),
        );
        expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
      },
    );

    test(
      'saved DeepSeek profile round trips in v1 without replacing custom TTS',
      () async {
        final settings = SpeechSettings();
        addTearDown(settings.dispose);
        await settings.save(_custom);
        final deepseek = _deepseek(voice: 'tide');
        await settings.save(deepseek);

        final restored = SpeechSettings();
        addTearDown(restored.dispose);
        await restored.restore();
        expect(restored.error, isNull);
        expect(restored.activeId, deepseek.id);
        expect(restored.active.toJson(), deepseek.toJson());
        expect(
          restored.profiles
              .singleWhere((profile) => profile.id == _custom.id)
              .toJson(),
          _custom.toJson(),
        );
        expect(
          restored.availableProfiles.where(
            (profile) => profile.provider == SpeechProvider.deepseek,
          ),
          hasLength(1),
        );
        await restored.select(_custom.id);
        expect(restored.active.toJson(), _custom.toJson());
        expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);

        await restored.remove(deepseek.id);
        expect(restored.activeId, _custom.id);
        expect(
          restored.profiles.any((profile) => profile.id == deepseek.id),
          isFalse,
        );
        final offeredAgain = restored.availableProfiles.singleWhere(
          (profile) => profile.provider == SpeechProvider.deepseek,
        );
        expect(offeredAgain.apiKey, isEmpty);
        expect(offeredAgain.voice, 'stella');
        expect(restored.active.toJson(), _custom.toJson());
      },
    );

    test(
      'an existing DeepSeek provider suppresses the unsaved preset',
      () async {
        final settings = SpeechSettings();
        addTearDown(settings.dispose);
        final existing = SpeechProfile.fromJson({
          ..._deepseek(voice: 'tide').toJson(),
          'id': 'user-deepseek-profile',
          'name': '已保存 DeepSeek',
        });
        await settings.save(existing);

        final available = settings.availableProfiles.where(
          (profile) => profile.provider == SpeechProvider.deepseek,
        );
        expect(available, hasLength(1));
        expect(available.single.toJson(), existing.toJson());
        expect(settings.activeId, existing.id);
      },
    );

    test(
      'custom profile with reserved preset ID stays intact without duplicate IDs',
      () async {
        final settings = SpeechSettings();
        addTearDown(settings.dispose);
        final existing = SpeechProfile.fromJson({
          ..._custom.toJson(),
          'id': SpeechProfile.deepseek.id,
        });
        await settings.save(existing);
        final secure = const FlutterSecureStorage();
        final before = await secure.read(key: SpeechSettings.storageKey);

        final restored = SpeechSettings();
        addTearDown(restored.dispose);
        await restored.restore();
        final available = restored.availableProfiles;
        expect(
          available.map((profile) => profile.id).toSet(),
          hasLength(available.length),
        );
        expect(
          available
              .singleWhere((profile) => profile.id == existing.id)
              .toJson(),
          existing.toJson(),
        );
        expect(
          available.any(
            (profile) => profile.provider == SpeechProvider.deepseek,
          ),
          isFalse,
        );
        expect(restored.activeId, existing.id);
        expect(restored.active.toJson(), existing.toJson());
        expect(restored.profiles.map((profile) => profile.id), [
          'system',
          existing.id,
        ]);
        expect(await secure.read(key: SpeechSettings.storageKey), before);
      },
    );
  });

  group('DeepSeek HTTP synthesis', () {
    test('request uses only DeepSeek fields and Bearer authentication', () {
      const text = '他说："你好"\n**中文🙂** 与 {voice}';
      final profile = SpeechProfile.fromJson({
        ..._deepseek(voice: 'tide').toJson(),
        'model': 'must-not-be-sent',
        'speed': 1.6,
        'instructions': 'must-not-be-sent-either',
      });
      final request = buildSpeechRequest(profile, text);

      expect(request.method, 'POST');
      expect(request.url.toString(), 'https://api.deepseek.com/v1/tools/tts');
      expect(request.followRedirects, isFalse);
      expect(request.headers['Authorization'], 'Bearer $_key');
      expect(request.headers['Content-Type'], startsWith('application/json'));
      expect(jsonDecode(request.body), {
        'text': text,
        'voice_id': 'tide',
        'format': 'wav',
        'filter_markdown': true,
      });
      expect(request.url.toString(), isNot(contains(_key)));
    });

    for (final voice in ['stella', 'tide']) {
      test('$voice returns complete WAV bytes for playback', () async {
        final audio = _wave(withMetadata: voice == 'tide');
        var calls = 0;
        final api = SpeechApi(
          clientFactory: () => MockClient((request) async {
            calls++;
            expect(request.url.toString(), SpeechProfile.deepseek.endpoint);
            expect(request.headers['Authorization'], 'Bearer $_key');
            expect(jsonDecode(request.body), {
              'text': 'DeepSeek 测试语音',
              'voice_id': voice,
              'format': 'wav',
              'filter_markdown': true,
            });
            return http.Response.bytes(
              audio,
              200,
              headers: {'content-type': 'audio/wav'},
            );
          }),
        );
        addTearDown(api.cancel);

        final result = await api.synthesize(
          _deepseek(voice: voice),
          'DeepSeek 测试语音',
        );
        expect(result, isA<Uint8List>());
        expect(result, orderedEquals(audio));
        expect(calls, 1);
      });
    }

    for (final key in ['', '   \n\t']) {
      test(
        'missing or whitespace key refuses synthesis without HTTP',
        () async {
          var calls = 0;
          final api = SpeechApi(
            clientFactory: () => MockClient((_) async {
              calls++;
              return http.Response.bytes(_wave(), 200);
            }),
          );
          addTearDown(api.cancel);

          await expectLater(
            api.synthesize(_deepseek(key: key), '不会发送'),
            throwsA(isA<SpeechFailure>()),
          );
          expect(calls, 0);
        },
      );
    }

    final malformed = <String, Uint8List>{
      'non-WAV audio': Uint8List.fromList([73, 68, 51, 0, 1, 2]),
      'JSON error with HTTP 200': Uint8List.fromList(
        utf8.encode('{"error":"private-provider-detail $_key"}'),
      ),
      'RIFF header only': Uint8List.fromList(ascii.encode('RIFF')),
      'truncated data': Uint8List.sublistView(_wave(), 0, _wave().length - 1),
      'missing fmt chunk': _waveWithChunks([
        _chunk('data', [0, 0, 1, 0]),
      ]),
      'missing data chunk': _waveWithChunks([_chunk('fmt ', _pcmFormat())]),
      'empty data chunk': _waveWithChunks([
        _chunk('fmt ', _pcmFormat()),
        _chunk('data', []),
      ]),
      'RIFF declared size exceeds response': _withSizeAt(_wave(), 4, 4096),
      'fmt declared size exceeds response': _withSizeAt(_wave(), 16, 4096),
      'data declared size exceeds response': _withSizeAt(_wave(), 40, 4096),
      'wrong WAVE marker': Uint8List.fromList(_wave())
        ..setRange(8, 12, ascii.encode('NOPE')),
    };
    for (final entry in malformed.entries) {
      test('rejects ${entry.key}', () async {
        final api = SpeechApi(
          clientFactory: () =>
              MockClient((_) async => http.Response.bytes(entry.value, 200)),
        );
        addTearDown(api.cancel);
        await expectLater(
          api.synthesize(_deepseek(), '错误样本'),
          throwsA(_safeFailure()),
        );
      });
    }

    test(
      'authentication and network errors do not expose keys or bodies',
      () async {
        final denied = SpeechApi(
          clientFactory: () => MockClient(
            (_) async => http.Response('private-provider-detail $_key', 401),
          ),
        );
        addTearDown(denied.cancel);
        await expectLater(
          denied.synthesize(_deepseek(), '鉴权失败样本'),
          throwsA(_safeFailure(containing: '鉴权失败')),
        );

        final disconnected = SpeechApi(
          clientFactory: () => MockClient((_) async {
            throw http.ClientException('private-provider-detail $_key');
          }),
        );
        addTearDown(disconnected.cancel);
        await expectLater(
          disconnected.synthesize(_deepseek(), '网络失败样本'),
          throwsA(_safeFailure()),
        );
      },
    );

    test(
      'cancellation rejects late WAV and the next synthesis can succeed',
      () async {
        final started = Completer<void>();
        final pending = Completer<http.Response>();
        var calls = 0;
        final audio = _wave();
        final api = SpeechApi(
          clientFactory: () => MockClient((_) async {
            calls++;
            if (calls == 1) {
              started.complete();
              return pending.future;
            }
            return http.Response.bytes(audio, 200);
          }),
        );
        addTearDown(api.cancel);

        final first = api.synthesize(_deepseek(), '取消的语音');
        final cancelled = expectLater(
          first,
          throwsA(_safeFailure(containing: '取消')),
        );
        await started.future;
        api.cancel();
        pending.complete(http.Response.bytes(audio, 200));
        await cancelled;
        expect(
          await api.synthesize(_deepseek(voice: 'tide'), '下一条语音'),
          orderedEquals(audio),
        );
        expect(calls, 2);
      },
    );
  });
}

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/voice_call_session.dart';
import 'package:ski/speech_api.dart';
import 'package:ski/speech_settings.dart';

class PendingSpeech extends SpeechApi {
  final result = Completer<Uint8List>();
  @override
  Future<Uint8List> synthesize(SpeechProfile p, String text) => result.future;
}

class VoiceFixtureBackend extends CurrentChatVoiceBackend {
  final result = Completer<String>();
  int replies = 0, cancellations = 0;
  @override
  Future<String> reply(String text, void Function(String) partial) {
    replies++;
    partial('fixture partial');
    return result.future;
  }

  @override
  Future<void> cancelReply() async {
    cancellations++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('skivu/voice_call');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });
  test(
    'call reports missing mic permission and never sends a fabricated chat',
    () async {
      final backend = VoiceFixtureBackend();
      messenger.setMockMethodCallHandler(
        channel,
        (m) async => m.method == 'listen' ? 'permission_required' : null,
      );
      final session = VoiceCallSession(backend: backend);
      await session.start();
      expect(session.needsPermission, isTrue);
      expect(session.phase, VoiceCallPhase.error);
      expect(backend.replies, 0);
      await session.setMuted(true);
      expect(session.phase, VoiceCallPhase.muted);
      await session.end();
      session.dispose();
    },
  );
  test(
    'unused settings preview cannot close the current call channel',
    () async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (m) async {
        calls.add(m.method);
        return m.method == 'listen' ? 'listening' : null;
      });
      final unused = VoiceCallSession();
      final active = VoiceCallSession();
      await active.start();
      await unused.end();
      expect(calls, isNot(contains('close')));
      await active.end();
      expect(calls.last, 'close');
      unused.dispose();
      active.dispose();
    },
  );
  test(
    'cancelled cloud preview neither plays late audio nor starts microphone',
    () async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (m) async {
        calls.add(m.method);
        return null;
      });
      final api = PendingSpeech();
      final session = VoiceCallSession(synthesis: api);
      final playing = session.previewVoice(
        profile: const SpeechProfile(
          id: 'cloud',
          name: 'Cloud',
          provider: SpeechProvider.openai,
          endpoint: 'https://voice.example/tts',
          voice: 'a',
          model: 'tts',
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(session.previewing, isTrue);
      await session.stopPreview();
      api.result.complete(Uint8List.fromList([73, 68, 51, 1]));
      await playing;
      expect(calls, isNot(contains('playAudio')));
      expect(calls, isNot(contains('listen')));
      await session.end();
      session.dispose();
    },
  );
  test(
    'hang-up invalidates a late reply without speaking or restarting capture',
    () async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (m) async {
        calls.add(m.method);
        return m.method == 'listen' ? 'listening' : null;
      });
      final backend = VoiceFixtureBackend();
      final session = VoiceCallSession(backend: backend);
      await session.start();
      final pending = session.sendText('fixture input');
      await Future<void>.delayed(Duration.zero);
      expect(session.phase, VoiceCallPhase.thinking);
      await session.end();
      backend.result.complete('late fixture reply');
      await pending;
      expect(session.phase, VoiceCallPhase.ended);
      expect(calls.where((m) => m == 'listen'), hasLength(1));
      expect(calls, isNot(contains('speak')));
      session.dispose();
    },
  );
  test(
    'call pauses capture during reply and waits for actual speech completion',
    () async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (m) async {
        calls.add(m.method);
        return m.method == 'listen' ? 'listening' : null;
      });
      final backend = VoiceFixtureBackend();
      final session = VoiceCallSession(backend: backend);
      await session.start();
      final turn = session.sendText('fixture input');
      await Future<void>.delayed(Duration.zero);
      backend.result.complete('fixture full reply');
      await Future<void>.delayed(Duration.zero);
      expect(session.phase, VoiceCallPhase.speaking);
      expect(calls.last, 'speak');
      await messenger.handlePlatformMessage(
        'skivu/voice_call',
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('ttsDone', {}),
        ),
        (_) {},
      );
      await turn;
      expect(session.phase, VoiceCallPhase.listening);
      expect(calls.last, 'listen');
      expect(session.transcript.first.text, 'fixture input');
      await session.end();
      session.dispose();
    },
  );
}

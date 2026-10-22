import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/voice_call_session.dart';

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

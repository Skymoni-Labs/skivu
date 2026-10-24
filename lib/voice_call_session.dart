// Current-app adapter for the user's migrated original call screen.
import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'state.dart';
import 'speech_settings.dart';
import 'speech_api.dart';

enum VoiceCallPhase {
  preparing,
  listening,
  userSpeaking,
  transcribing,
  thinking,
  speaking,
  muted,
  error,
  ended,
}

class CallTranscriptEntry {
  CallTranscriptEntry(this.id, this.speaker, this.text);
  final String id, speaker;
  String text;
}

class VoiceReplyPart {
  const VoiceReplyPart(this.id, this.speaker, this.text);
  final String id, speaker, text;
}

class CurrentChatVoiceBackend extends ChangeNotifier {
  CurrentChatVoiceBackend({DemoStore? store}) : store = store ?? demo;
  final DemoStore store;
  List<VoiceReplyPart> _replyParts = const [];
  List<VoiceReplyPart> get replyParts => List.unmodifiable(_replyParts);
  String get speakerName =>
      store.conversations[store.conversation].groupMembers.isNotEmpty
      ? '群聊'
      : store.role.name;
  bool get hasLocalVoice => false;
  bool get usesLocalVoice => false;
  String get speechDescription =>
      '系统语音识别 · ${speechSettings.active.name}合成。对话使用当前模型与额度。';
  bool _ownsReply = false;
  VoidCallback? _listener;
  Completer<String>? _pending;
  Future<String> reply(String text, void Function(String) partial) async {
    if (store.streaming || _pending != null) throw StateError('请先等待当前文字回复结束。');
    _replyParts = const [];
    final chat = store.conversations[store.conversation];
    final before = chat.messages.toSet();
    if (!store.send(text, immediate: true, kind: 'voice'))
      throw StateError(store.lastError ?? '请先选择可用模型。');
    final turn = chat.messages
        .where((m) => m.user && !before.contains(m))
        .lastOrNull;
    _ownsReply = store.streaming;
    final done = _pending = Completer<String>();
    void update() {
      if (done.isCompleted) return;
      if (!identical(store.conversations[store.conversation], chat)) {
        done.completeError(StateError('对话已切换，本轮语音回复已停止。'));
        return;
      }
      final answers = chat.messages
          .where(
            (m) =>
                !m.user &&
                !before.contains(m) &&
                (turn?.turnId == null || m.turnId == turn!.turnId),
          )
          .toList();
      String name(Message message) =>
          store.personas
              .where((p) => p.id == message.authorId)
              .firstOrNull
              ?.name ??
          store.role.name;
      partial(
        answers
            .map(
              (m) => chat.groupMembers.isNotEmpty
                  ? '${name(m)}：${m.text}'
                  : m.text,
            )
            .join('\n\n'),
      );
      if (!store.streaming) {
        final failed = answers.where((m) => m.status == 'failed').firstOrNull;
        if (failed != null) {
          done.completeError(StateError(failed.error ?? '对话暂未完成，请重试。'));
          return;
        }
        _replyParts = [
          for (final answer in answers)
            if (answer.status == 'complete' && answer.text.trim().isNotEmpty)
              VoiceReplyPart(
                answer.created.toIso8601String(),
                name(answer),
                answer.text,
              ),
        ];
        // A mention-only group may intentionally have no assistant response.
        // User input and replies belonging to an earlier turn never enter TTS.
        done.complete(_replyParts.map((m) => m.text).join('\n\n'));
      }
    }

    _listener = update;
    store.addListener(update);
    update();
    try {
      return await done.future;
    } finally {
      store.removeListener(update);
      _listener = null;
      _pending = null;
      _ownsReply = false;
    }
  }

  Future<void> cancelReply() async {
    if (_ownsReply) store.stop();
    if (_pending?.isCompleted == false) _pending!.complete('');
  }

  @override
  void dispose() {
    if (_listener != null) store.removeListener(_listener!);
    if (_pending?.isCompleted == false) _pending!.complete('');
    super.dispose();
  }
}

class VoiceCallSession extends ChangeNotifier {
  static VoiceCallSession? _owner;
  VoiceCallSession({
    CurrentChatVoiceBackend? backend,
    MethodChannel? channel,
    SpeechSettings? speech,
    SpeechApi? synthesis,
  }) : backend = backend ?? CurrentChatVoiceBackend(),
       speech = speech ?? speechSettings,
       synthesis = synthesis ?? SpeechApi(),
       _channel = channel ?? const MethodChannel('skivu/voice_call');
  final SpeechSettings speech;
  final SpeechApi synthesis;
  final CurrentChatVoiceBackend backend;
  final MethodChannel _channel;
  void _claim() {
    _owner = this;
    _channel.setMethodCallHandler(_event);
  }

  final level = ValueNotifier<double>(0);
  final elapsed = Stopwatch();
  final transcript = <CallTranscriptEntry>[];
  VoiceCallPhase phase = VoiceCallPhase.preparing;
  bool muted = false, needsPermission = false, previewing = false;
  String? error;
  bool _closed = false, _disposed = false, _ready = false, _turnBusy = false;
  int _generation = 0, _listenFailures = 0;
  Timer? _retry;
  Completer<void>? _spoken;
  bool get canSendText => !_closed && !_turnBusy;
  String get diagnosticReport => jsonEncode({
    'phase': phase.name,
    'elapsedSeconds': elapsed.elapsed.inSeconds,
    'turns': transcript.where((t) => t.speaker == '你').length,
  });
  void _change(VoiceCallPhase next) {
    if (_closed && next != VoiceCallPhase.ended) return;
    phase = next;
    if (!_disposed) notifyListeners();
  }

  Future<void> start({bool requestPermission = false}) async {
    if (_closed || _turnBusy) return;
    error = null;
    needsPermission = false;
    _claim();
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      error = '语音通话请在 Android 客户端使用。';
      _change(VoiceCallPhase.error);
      return;
    }
    try {
      await _prepare();
      if (_closed) return;
      _ready = true;
      muted = false;
      await _listen(requestPermission: requestPermission);
    } on PlatformException catch (e) {
      error = e.message ?? '系统语音暂不可用；可以从更多中输入文字。';
      _change(VoiceCallPhase.error);
    } catch (_) {
      error = '系统语音暂不可用；可以从更多中输入文字。';
      _change(VoiceCallPhase.error);
    }
  }

  Future<void> _listen({bool requestPermission = false}) async {
    if (_closed || muted || _turnBusy) return;
    final result = await _channel.invokeMethod<String>('listen', {
      'requestPermission': requestPermission,
    });
    if (_closed || muted || _turnBusy) return;
    if (result == 'permission_required') {
      needsPermission = true;
      error = '请允许麦克风权限。';
      _change(VoiceCallPhase.error);
    } else {
      elapsed.start();
      _change(VoiceCallPhase.listening);
    }
  }

  Future<void> _event(MethodCall event) async {
    if (_closed) return;
    final args = event.arguments is Map ? event.arguments as Map : {};
    switch (event.method) {
      case 'level':
        if (!muted && !_turnBusy) {
          level.value = ((args['value'] as num? ?? 0) / 10)
              .clamp(0, 1)
              .toDouble();
        }
        break;
      case 'speech':
        if (!muted && !_turnBusy) _change(VoiceCallPhase.userSpeaking);
        break;
      case 'result':
        final text = args['text'] as String? ?? '';
        if (!muted && !_turnBusy && text.trim().isNotEmpty) {
          _listenFailures = 0;
          unawaited(sendText(text));
        }
        break;
      case 'recognitionError':
        if (muted || _turnBusy) break;
        final code = args['code'] as int?;
        if ([6, 7].contains(code) && _listenFailures++ < 3) {
          _retry?.cancel();
          _retry = Timer(const Duration(milliseconds: 500), () {
            if (!_closed && !muted && !_turnBusy) unawaited(_resume());
          });
        } else {
          error = '系统没有听清语音，请重试麦克风或输入文字。';
          level.value = 0;
          _change(VoiceCallPhase.error);
        }
        break;
      case 'ttsDone':
        if (_spoken?.isCompleted == false) _spoken!.complete();
        break;
      case 'ttsError':
        if (_spoken?.isCompleted == false)
          _spoken!.completeError(StateError('语音播放失败，请检查语音服务和音频格式。'));
        break;
    }
  }

  Future<void> _resume() async {
    try {
      await _listen();
    } catch (_) {
      error = '语音识别暂不可用，请重新开启麦克风。';
      _change(VoiceCallPhase.error);
    }
  }

  Future<void> _prepare([SpeechProfile? profile]) => _channel.invokeMethod(
    'prepare',
    {'systemTts': (profile ?? speech.active).provider == SpeechProvider.system},
  );

  Future<void> _speak(String text, {SpeechProfile? profile}) async {
    if (text.trim().isEmpty || _closed) return;
    final done = _spoken = Completer<void>();
    level.value = .4;
    _change(VoiceCallPhase.speaking);
    try {
      final selected = profile ?? speech.active;
      if (selected.provider == SpeechProvider.system) {
        await _channel.invokeMethod('speak', {
          'text': text,
          'speed': selected.speed,
          'voice': selected.voice,
        });
      } else {
        final bytes = await synthesis.synthesize(selected, text);
        if (_closed || !identical(_spoken, done) || done.isCompleted) return;
        await _channel.invokeMethod('playAudio', {'bytes': bytes});
      }
      await done.future.timeout(const Duration(minutes: 10));
    } finally {
      if (identical(_spoken, done)) _spoken = null;
      level.value = 0;
    }
  }

  Future<void> sendText(String text) async {
    if (!canSendText || text.trim().isEmpty) return;
    final generation = ++_generation;
    _turnBusy = true;
    _retry?.cancel();
    transcript.add(CallTranscriptEntry('user-${transcript.length}', '你', text));
    final answer = CallTranscriptEntry(
      'assistant-${transcript.length}',
      backend.speakerName,
      '',
    );
    transcript.add(answer);
    try {
      if (_ready) await _channel.invokeMethod('stopListening');
      if (_closed || generation != _generation) return;
      _change(VoiceCallPhase.thinking);
      final reply = await backend.reply(text, (partial) {
        if (!_closed && generation == _generation) {
          answer.text = partial;
          if (!_disposed) notifyListeners();
        }
      });
      if (_closed || generation != _generation) return;
      final parts = backend.replyParts;
      if (parts.isEmpty) {
        answer.text = reply;
        if (reply.trim().isEmpty) transcript.remove(answer);
        if (_ready && reply.isNotEmpty) await _speak(reply);
      } else {
        final index = transcript.indexOf(answer);
        if (index >= 0) {
          transcript.removeAt(index);
          transcript.insertAll(index, [
            for (final part in parts)
              CallTranscriptEntry(
                'assistant-${generation}-${part.id}',
                part.speaker,
                part.text,
              ),
          ]);
        }
        if (!_disposed) notifyListeners();
        if (_ready) {
          for (final part in parts) {
            if (_closed || generation != _generation) break;
            await _speak(part.text);
          }
        }
      }
    } catch (e) {
      if (!_closed && generation == _generation) {
        error = e is SpeechFailure
            ? e.message
            : e is StateError
            ? e.message.toString()
            : '通话暂时中断，请重试。';
        _change(VoiceCallPhase.error);
      }
    } finally {
      if (generation == _generation && !_closed) {
        _turnBusy = false;
        if (phase != VoiceCallPhase.error) {
          if (muted) {
            _change(VoiceCallPhase.muted);
          } else if (_ready) {
            await _resume();
          } else {
            _change(VoiceCallPhase.muted);
          }
        }
      }
    }
  }

  Future<void> interrupt() async {
    ++_generation;
    _turnBusy = false;
    previewing = false;
    _retry?.cancel();
    synthesis.cancel();
    if (_spoken?.isCompleted == false) _spoken!.complete();
    await backend.cancelReply();
    if (_ready && identical(_owner, this)) {
      try {
        await _channel.invokeMethod('stop');
      } catch (_) {}
    }
    level.value = 0;
    if (!_closed) {
      if (muted) {
        _change(VoiceCallPhase.muted);
      } else if (_ready) {
        await _resume();
      }
    }
  }

  Future<void> setMuted(bool value) async {
    if (_closed) return;
    muted = value;
    if (value) {
      await interrupt();
    } else {
      error = null;
      _listenFailures = 0;
      if (_ready) {
        await _resume();
      } else {
        await start(requestPermission: true);
      }
    }
  }

  Future<void> previewVoice({
    SpeechProfile? profile,
    String text = '你好，我在这里。你可以慢慢说。',
  }) async {
    if (_closed || _turnBusy) return;
    final generation = ++_generation;
    _turnBusy = true;
    previewing = true;
    error = null;
    try {
      _claim();
      await _prepare(profile);
      _ready = true;
      await _channel.invokeMethod('stopListening');
      await _speak(text, profile: profile);
    } catch (failure) {
      if (!_closed && generation == _generation) {
        error = failure is SpeechFailure
            ? failure.message
            : '语音试听失败，请检查服务配置或系统朗读引擎。';
        _change(VoiceCallPhase.error);
      }
    } finally {
      _turnBusy = false;
      previewing = false;
      if (!_closed && generation == _generation) {
        muted = true;
        if (phase != VoiceCallPhase.error) _change(VoiceCallPhase.muted);
      }
    }
  }

  Future<void> stopPreview() async {
    if (!previewing || _closed) return;
    muted = true;
    await interrupt();
  }

  Future<void> selectLocalVoice(bool selected) async {}
  Future<void> end() async {
    if (_closed) return;
    _closed = true;
    ++_generation;
    _retry?.cancel();
    synthesis.cancel();
    elapsed.stop();
    if (_spoken?.isCompleted == false) _spoken!.complete();
    await backend.cancelReply();
    if (identical(_owner, this)) {
      _owner = null;
      _channel.setMethodCallHandler(null);
      try {
        await _channel.invokeMethod('close');
      } catch (_) {}
    }
    level.value = 0;
    _change(VoiceCallPhase.ended);
  }

  @override
  void dispose() {
    unawaited(end());
    _disposed = true;
    backend
        .dispose(); /* end owns asynchronous native cleanup; orb no longer listens after unmount. */
    super.dispose();
  }
}

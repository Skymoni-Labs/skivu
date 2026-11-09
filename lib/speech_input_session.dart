import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'speech_recognition.dart';
import 'speech_recognition_settings.dart';
import 'speech_settings.dart';
import 'voice_channel_lease.dart';

class SpeechInputSession extends ChangeNotifier with WidgetsBindingObserver {
  SpeechInputSession({SpeechSettings? settings, MethodChannel? channel})
    : settings = settings ?? speechSettings,
      channel = channel ?? const MethodChannel('skivu/voice_call');
  final SpeechSettings settings;
  final MethodChannel channel;
  Completer<String>? _pending;
  SpeechRecognition? _recognition;
  String partial = '', phase = 'idle';
  bool _disposed = false;
  void _update() {
    if (!_disposed) notifyListeners();
  }

  Future<String> listen() async {
    if (_pending != null) throw const FormatException('识别正在进行。');
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      throw const FormatException('请在 Android 客户端使用麦克风。');
    }
    VoiceChannelLease.claim(channel, this, _event);
    WidgetsBinding.instance.addObserver(this);
    final done = _pending = Completer<String>();
    done.future.ignore();
    final recognition = _recognition = SpeechRecognition(
      channel,
      settings.recognition,
      _event,
    );
    try {
      partial = '';
      phase = 'listening';
      _update();
      final status = await recognition.start(requestPermission: true);
      if (done.isCompleted) return await done.future;
      if (status == 'permission_required')
        throw const FormatException('请允许麦克风权限。');
      return await done.future;
    } on PlatformException catch (e) {
      throw FormatException(e.message ?? '语音服务暂不可用。');
    } finally {
      WidgetsBinding.instance.removeObserver(this);
      recognition.cancel();
      if (VoiceChannelLease.owns(channel, this)) {
        try {
          await channel.invokeMethod('stopListening');
        } finally {
          VoiceChannelLease.release(channel, this);
        }
      }
      _pending = null;
      _recognition = null;
      phase = 'idle';
      _update();
    }
  }

  Future<void> _event(MethodCall event) async {
    if (await _recognition?.handle(event) == true) return;
    final done = _pending;
    if (done == null || done.isCompleted) return;
    final args = event.arguments is Map ? event.arguments as Map : {};
    switch (event.method) {
      case 'partial':
        partial = args['text']?.toString() ?? '';
        _update();
      case 'transcribing':
        phase = 'transcribing';
        _update();
      case 'result':
        final text = args['text']?.toString() ?? '';
        if (text.trim().isEmpty)
          done.completeError(const FormatException('没有识别出文字，请重试。'));
        else
          done.complete(text);
      case 'recognitionError':
        done.completeError(
          FormatException(
            args['message']?.toString() ??
                recognitionErrorMessage((args['code'] as num?)?.toInt()),
          ),
        );
    }
  }

  Future<void> finish() async {
    if (_pending != null && phase == 'listening') {
      phase = 'transcribing';
      _update();
      await _recognition?.finish();
    }
  }

  void cancel() {
    _recognition?.cancel();
    if (_pending?.isCompleted == false)
      _pending!.completeError(const FormatException('已取消识别'));
    if (VoiceChannelLease.owns(channel, this)) {
      unawaited(
        channel.invokeMethod<void>('stopListening').catchError((Object _) {}),
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached)
      cancel();
  }

  @override
  void dispose() {
    cancel();
    _disposed = true;
    super.dispose();
  }
}

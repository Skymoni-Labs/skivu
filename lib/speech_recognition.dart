import 'package:flutter/services.dart';
import 'speech_recognition_settings.dart';
import 'speech_recognition_upload.dart';

/// Uses native Android recognition by default; custom capture uploads only to
/// the service explicitly selected in the local recognition settings.
class SpeechRecognition {
  SpeechRecognition(this.channel, this.profile, this.emit);
  final MethodChannel channel;
  final RecognitionProfile profile;
  final Future<void> Function(MethodCall) emit;
  final upload = RecognitionUpload();
  bool _closed = false;
  bool get custom => profile.provider != RecognitionProvider.system;
  Future<String?> start({required bool requestPermission}) async {
    profile.validate();
    return channel.invokeMethod<String>(custom ? 'record' : 'listen', {
      'requestPermission': requestPermission,
      'language': profile.language,
      'preferOnDevice': profile.preferOnDevice,
      'silenceMillis': profile.silenceMillis,
    });
  }

  Future<void> finish() =>
      channel.invokeMethod(custom ? 'finishRecording' : 'finishListening');
  Future<bool> handle(MethodCall event) async {
    if (event.method != 'recorded') return false;
    final data = Map<String, dynamic>.from(event.arguments as Map);
    final path = data['path'] as String;
    try {
      if (_closed) return true;
      await emit(const MethodCall('transcribing'));
      final text = await upload.transcribe(profile, path);
      if (!_closed) await emit(MethodCall('result', {'text': text}));
    } catch (e) {
      if (!_closed)
        await emit(
          MethodCall('recognitionError', {
            'message': e is FormatException ? e.message : '识别请求已中断，请检查网络或重试。',
          }),
        );
    } finally {
      await channel.invokeMethod('discardRecording', {'path': path});
    }
    return true;
  }

  void cancel() {
    _closed = true;
    upload.cancel();
  }
}

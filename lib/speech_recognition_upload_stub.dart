import 'speech_recognition_settings.dart';

class RecognitionUpload {
  Future<String> transcribe(RecognitionProfile profile, String path) async =>
      throw const FormatException('请在 Android 客户端使用语音识别。');
  void cancel() {}
}

import 'dart:convert';
import 'speech_settings.dart';

enum RecognitionProvider { system, openai, custom }

class RecognitionProfile {
  const RecognitionProfile({
    this.provider = RecognitionProvider.system,
    this.endpoint = '',
    this.apiKey = '',
    this.model = '',
    this.language = 'zh-CN',
    this.preferOnDevice = false,
    this.headers = '{}',
    this.fields = '{"model":"{model}","language":"{language}"}',
    this.audioField = 'file',
    this.transport = 'multipart',
    this.responsePath = 'text',
    this.silenceMillis = 1200,
    this.timeoutSeconds = 0,
  });
  final RecognitionProvider provider;
  final String endpoint,
      apiKey,
      model,
      language,
      headers,
      fields,
      audioField,
      transport,
      responsePath;
  final bool preferOnDevice;
  final int silenceMillis, timeoutSeconds;
  String get label => switch (provider) {
    RecognitionProvider.system => 'Android 系统识别',
    RecognitionProvider.openai => 'OpenAI 兼容识别',
    RecognitionProvider.custom => '自定义识别服务',
  };
  void validate() {
    if (silenceMillis < 0 || timeoutSeconds < 0) {
      throw const FormatException('等待时间不能为负数；0 表示手动结束或不设置超时。');
    }
    if (provider == RecognitionProvider.system) return;
    speechUri(endpoint);
    if (provider == RecognitionProvider.openai && model.trim().isEmpty) {
      throw const FormatException('请填写识别模型 ID。');
    }
    final extra = jsonDecode(headers);
    if (extra is! Map || extra.values.any((v) => v is! String)) {
      throw const FormatException('请求头应为 JSON 字符串对象。');
    }
    final data = jsonDecode(fields);
    if (data is! Map) throw const FormatException('附加字段应为 JSON 对象。');
    if (!['multipart', 'json'].contains(transport)) {
      throw const FormatException('请选择 multipart 或 JSON。');
    }
    if (audioField.trim().isEmpty) throw const FormatException('请填写音频字段名。');
  }

  Map<String, dynamic> toJson() => {
    'provider': provider.name,
    'endpoint': endpoint,
    'apiKey': apiKey,
    'model': model,
    'language': language,
    'preferOnDevice': preferOnDevice,
    'headers': headers,
    'fields': fields,
    'audioField': audioField,
    'transport': transport,
    'responsePath': responsePath,
    'silenceMillis': silenceMillis,
    'timeoutSeconds': timeoutSeconds,
  };
  factory RecognitionProfile.fromJson(Map<String, dynamic> j) =>
      RecognitionProfile(
        provider: RecognitionProvider.values.byName(
          j['provider'] as String? ?? 'system',
        ),
        endpoint: j['endpoint'] as String? ?? '',
        apiKey: j['apiKey'] as String? ?? '',
        model: j['model'] as String? ?? '',
        language: j['language'] as String? ?? 'zh-CN',
        preferOnDevice: j['preferOnDevice'] == true,
        headers: j['headers'] as String? ?? '{}',
        fields:
            j['fields'] as String? ??
            '{"model":"{model}","language":"{language}"}',
        audioField: j['audioField'] as String? ?? 'file',
        transport: j['transport'] as String? ?? 'multipart',
        responsePath: j['responsePath'] as String? ?? 'text',
        silenceMillis: (j['silenceMillis'] as num?)?.toInt() ?? 1200,
        timeoutSeconds: (j['timeoutSeconds'] as num?)?.toInt() ?? 0,
      );
}

String recognitionErrorMessage(int? code) => switch (code) {
  1 => '系统识别连接超时，请检查网络或选择本机识别。',
  2 => '系统识别网络连接失败，请检查网络。',
  3 => '麦克风录音失败，请检查是否被其他应用占用。',
  4 => '系统语音识别服务返回错误，请稍后重试或切换识别服务。',
  5 => '系统识别会话已中断，请重新开始。',
  6 => '没有听到语音，请靠近麦克风后重新开始。',
  7 => '没有识别出文字，请重新说一次或修改识别语言。',
  8 => '系统识别服务正忙，请结束其他收音后重试。',
  9 => '麦克风权限未开启，请在系统设置中允许。',
  10 => '系统识别服务请求过于频繁，请稍后重试。',
  11 => '系统语音识别服务已断开，请重新开始。',
  12 => '系统识别不支持此语言，请修改识别语言。',
  13 => '此语言的识别资源尚未安装，请在系统语音服务中下载。',
  _ => '语音识别暂不可用，请检查识别服务后重试。',
};

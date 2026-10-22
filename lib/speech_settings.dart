import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

enum SpeechProvider { system, openai, elevenlabs, azure, custom }

extension SpeechProviderLabel on SpeechProvider {
  String get label => switch (this) {
    SpeechProvider.system => 'Android 系统语音',
    SpeechProvider.openai => 'OpenAI 兼容 TTS',
    SpeechProvider.elevenlabs => 'ElevenLabs',
    SpeechProvider.azure => 'Azure Speech',
    SpeechProvider.custom => '自定义 HTTP',
  };
}

class SpeechProfile {
  const SpeechProfile({
    required this.id,
    this.name = '系统默认',
    this.provider = SpeechProvider.system,
    this.endpoint = '',
    this.apiKey = '',
    this.model = '',
    this.voice = '',
    this.speed = 1,
    this.method = 'POST',
    this.headers = '{}',
    this.body =
        '{"text":"{text}","model":"{model}","voice":"{voice}","speed":"{speed}"}',
    this.response = 'audio',
    this.responsePath = 'audio',
    this.instructions = '',
  });
  static const system = SpeechProfile(id: 'system');
  final String id,
      name,
      endpoint,
      apiKey,
      model,
      voice,
      method,
      headers,
      body,
      response,
      responsePath,
      instructions;
  final SpeechProvider provider;
  final double speed;

  void validate() {
    if (name.trim().isEmpty) throw const FormatException('请填写连接名称');
    if (!speed.isFinite || speed < .5 || speed > 2)
      throw const FormatException('语速需在 0.5～2.0 之间');
    if (provider == SpeechProvider.system) return;
    speechUri(endpoint);
    if (provider != SpeechProvider.custom && voice.trim().isEmpty)
      throw const FormatException('请填写音色 ID');
    if ([SpeechProvider.openai, SpeechProvider.elevenlabs].contains(provider) &&
        model.trim().isEmpty) {
      throw const FormatException('请填写语音模型 ID');
    }
    if (provider == SpeechProvider.elevenlabs && (speed < .7 || speed > 1.2)) {
      throw const FormatException('ElevenLabs 语速范围为 0.7～1.2');
    }
    if (provider == SpeechProvider.custom) {
      if (!['GET', 'POST'].contains(method))
        throw const FormatException('请选择 GET 或 POST');
      final extra = jsonDecode(headers);
      if (extra is! Map || extra.values.any((v) => v is! String))
        throw const FormatException('请求头应为 JSON 字符串对象');
      if (method == 'POST' && jsonDecode(body) is! Map)
        throw const FormatException('请求体应为 JSON 对象');
      if (!['audio', 'base64', 'hex', 'url'].contains(response))
        throw const FormatException('请选择音频返回方式');
      if (response != 'audio' && responsePath.trim().isEmpty)
        throw const FormatException('请填写音频字段路径');
    }
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'provider': provider.name,
    'endpoint': endpoint,
    'apiKey': apiKey,
    'model': model,
    'voice': voice,
    'speed': speed,
    'method': method,
    'headers': headers,
    'body': body,
    'response': response,
    'responsePath': responsePath,
    'instructions': instructions,
  };
  factory SpeechProfile.fromJson(Map<String, dynamic> j) => SpeechProfile(
    id: j['id'] as String,
    name: j['name'] as String,
    provider: SpeechProvider.values.byName(j['provider'] as String),
    endpoint: j['endpoint'] as String? ?? '',
    apiKey: j['apiKey'] as String? ?? '',
    model: j['model'] as String? ?? '',
    voice: j['voice'] as String? ?? '',
    speed: (j['speed'] as num? ?? 1).toDouble(),
    method: j['method'] as String? ?? 'POST',
    headers: j['headers'] as String? ?? '{}',
    body: j['body'] as String? ?? '{}',
    response: j['response'] as String? ?? 'audio',
    responsePath: j['responsePath'] as String? ?? 'audio',
    instructions: j['instructions'] as String? ?? '',
  );
}

Uri speechUri(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      !['https', 'http'].contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment) {
    throw const FormatException('请填写完整的 HTTP(S) 服务地址，不要在地址中填写账号密码');
  }
  return uri;
}

/// All fields, including custom headers/templates, stay in secure storage.
/// This configuration is deliberately absent from chat/appearance exports.
class SpeechSettings extends ChangeNotifier {
  SpeechSettings({FlutterSecureStorage? secure})
    : _secure = secure ?? const FlutterSecureStorage();
  final FlutterSecureStorage _secure;
  static const storageKey = 'skivu.speech.v1';
  List<SpeechProfile> profiles = [SpeechProfile.system];
  String activeId = 'system';
  String? error;
  SpeechProfile get active =>
      profiles.where((p) => p.id == activeId).firstOrNull ??
      SpeechProfile.system;
  Future<void> restore() async {
    try {
      final raw = await _secure.read(key: storageKey);
      if (raw == null) return;
      final j = jsonDecode(raw) as Map;
      final next = (j['profiles'] as List)
          .map((p) => SpeechProfile.fromJson(Map<String, dynamic>.from(p)))
          .toList();
      for (final p in next) {
        p.validate();
      }
      if (!next.any((p) => p.id == 'system'))
        next.insert(0, SpeechProfile.system);
      profiles = next;
      activeId = j['activeId'] as String;
      if (!profiles.any((p) => p.id == activeId)) activeId = 'system';
    } catch (_) {
      error = '语音配置读取失败，请重新检查连接。';
    }
    notifyListeners();
  }

  Future<void> _write(List<SpeechProfile> next, String id) async {
    await _secure.write(
      key: storageKey,
      value: jsonEncode({
        'activeId': id,
        'profiles': next.map((p) => p.toJson()).toList(),
      }),
    );
    profiles = next;
    activeId = id;
    error = null;
    notifyListeners();
  }

  Future<void> save(SpeechProfile profile) async {
    profile.validate();
    final next = [...profiles];
    final index = next.indexWhere((p) => p.id == profile.id);
    if (index < 0) {
      next.add(profile);
    } else {
      next[index] = profile;
    }
    await _write(next, profile.id);
  }

  Future<void> select(String id) async {
    if (profiles.any((p) => p.id == id)) await _write(profiles, id);
  }

  Future<void> remove(String id) async {
    if (id == 'system') return;
    await _write(
      profiles.where((p) => p.id != id).toList(),
      activeId == id ? 'system' : activeId,
    );
  }
}

final speechSettings = SpeechSettings();

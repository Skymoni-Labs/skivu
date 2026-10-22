import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'speech_settings.dart';

class SpeechFailure implements Exception {
  const SpeechFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

class SpeechApi {
  SpeechApi({http.Client Function()? clientFactory})
    : _factory = clientFactory ?? http.Client.new;
  final http.Client Function() _factory;
  http.Client? _client;
  int _generation = 0;
  static const maxBytes = 10 * 1024 * 1024;
  void cancel() {
    _generation++;
    _client?.close();
    _client = null;
  }

  Future<Uint8List> synthesize(SpeechProfile p, String text) async {
    p.validate();
    cancel();
    final generation = _generation;
    final client = _client = _factory();
    try {
      if (text.trim().isEmpty || text.length > 10000)
        throw const SpeechFailure('每次语音文字需在 1～10000 字符以内。');
      final request = buildSpeechRequest(p, text);
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 45));
      if (response.statusCode != 200)
        throw SpeechFailure(switch (response.statusCode) {
          401 || 403 => '语音鉴权失败，请检查密钥和音色权限。',
          404 => '未找到语音接口、模型或音色，请核对配置。',
          429 => '语音服务限流或额度不足，请稍后重试。',
          _ => '语音合成失败（${response.statusCode}），请检查接口配置。',
        });
      var bytes = await _read(response);
      if (p.provider == SpeechProvider.custom && p.response != 'audio') {
        dynamic value = jsonDecode(utf8.decode(bytes));
        for (final key in p.responsePath.split('.')) {
          value = value is List ? value[int.parse(key)] : (value as Map)[key];
        }
        if (value is! String || value.isEmpty)
          throw const SpeechFailure('语音返回字段为空，请检查字段路径。');
        if (p.response == 'base64') {
          bytes = base64Decode(
            value.contains(',') && value.startsWith('data:')
                ? value.split(',').last
                : value,
          );
        } else if (p.response == 'hex') {
          if (value.length.isOdd ||
              !RegExp(r'^[0-9a-fA-F]+$').hasMatch(value)) {
            throw const SpeechFailure('音频 Hex 字段格式不正确。');
          }
          bytes = Uint8List.fromList([
            for (var i = 0; i < value.length; i += 2)
              int.parse(value.substring(i, i + 2), radix: 16),
          ]);
        } else {
          // Audio URLs never inherit the synthesis request's credentials.
          final audio = await client
              .send(
                http.Request('GET', speechUri(value))..followRedirects = false,
              )
              .timeout(const Duration(seconds: 45));
          if (audio.statusCode != 200) throw const SpeechFailure('音频地址下载失败。');
          bytes = await _read(audio);
        }
      }
      if (generation != _generation) throw const SpeechFailure('语音已取消');
      if (bytes.isEmpty || bytes.length > maxBytes)
        throw const SpeechFailure('音频为空或超过 10 MB，请缩短文字。');
      // JSON/HTML errors are not playable audio even if a service returns 200.
      final prefix = utf8
          .decode(bytes.take(40).toList(), allowMalformed: true)
          .trimLeft();
      if (prefix.startsWith('{') || prefix.startsWith('<'))
        throw const SpeechFailure('接口返回了文本而非音频，请检查返回方式。');
      return bytes;
    } on SpeechFailure {
      rethrow;
    } on FormatException {
      throw const SpeechFailure('语音请求或响应格式不匹配，请检查模板和字段路径。');
    } catch (_) {
      throw const SpeechFailure('语音连接失败或超时，请检查地址与网络。');
    } finally {
      client.close();
      if (identical(_client, client)) _client = null;
    }
  }

  Future<Uint8List> _read(http.StreamedResponse response) async {
    if ((response.contentLength ?? 0) > maxBytes)
      throw const SpeechFailure('音频超过 10 MB，请缩短文字。');
    final result = BytesBuilder(copy: false);
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 45),
    )) {
      result.add(chunk);
      if (result.length > maxBytes)
        throw const SpeechFailure('音频超过 10 MB，请缩短文字。');
    }
    return result.takeBytes();
  }
}

http.Request buildSpeechRequest(SpeechProfile p, String text) {
  final values = <String, dynamic>{
    'text': text,
    'model': p.model,
    'voice': p.voice,
    'speed': p.speed,
    'key': p.apiKey,
  };
  String substitute(String value, {bool url = false}) {
    for (final entry in values.entries) {
      value = value.replaceAll(
        '{${entry.key}}',
        url ? Uri.encodeComponent('${entry.value}') : '${entry.value}',
      );
    }
    return value;
  }

  dynamic template(dynamic value) {
    if (value is String) {
      for (final entry in values.entries) {
        if (value == '{${entry.key}}') return entry.value;
      }
      return substitute(value);
    }
    if (value is Map) return value.map((k, v) => MapEntry(k, template(v)));
    if (value is List) return value.map(template).toList();
    return value;
  }

  final uri = speechUri(substitute(p.endpoint, url: true));
  final request = http.Request(
    p.provider == SpeechProvider.custom ? p.method : 'POST',
    uri,
  )..followRedirects = false;
  request.headers['Content-Type'] = 'application/json';
  request.headers['Accept'] = 'audio/mpeg, audio/wav, application/octet-stream';
  switch (p.provider) {
    case SpeechProvider.system:
      throw const SpeechFailure('系统语音无需 HTTP 请求。');
    case SpeechProvider.openai:
      if (p.apiKey.isNotEmpty)
        request.headers['Authorization'] = 'Bearer ${p.apiKey}';
      request.body = jsonEncode({
        'model': p.model,
        'input': text,
        'voice': p.voice,
        'speed': p.speed,
        'response_format': 'mp3',
        if (p.instructions.isNotEmpty) 'instructions': p.instructions,
      });
    case SpeechProvider.elevenlabs:
      final base = uri.path.endsWith('/')
          ? uri.path.substring(0, uri.path.length - 1)
          : uri.path;
      if (!base.contains('/text-to-speech/'))
        throw const SpeechFailure('ElevenLabs 地址需包含 /text-to-speech/音色ID。');
      request.headers['xi-api-key'] = p.apiKey;
      request.body = jsonEncode({
        'text': text,
        'model_id': p.model,
        'voice_settings': {'speed': p.speed},
      });
    case SpeechProvider.azure:
      String xml(String value) => value
          .replaceAll('&', '&amp;')
          .replaceAll('<', '&lt;')
          .replaceAll('>', '&gt;')
          .replaceAll('"', '&quot;')
          .replaceAll("'", '&apos;');
      request.headers.addAll({
        'Content-Type': 'application/ssml+xml',
        'Ocp-Apim-Subscription-Key': p.apiKey,
        'X-Microsoft-OutputFormat': 'audio-24khz-48kbitrate-mono-mp3',
      });
      final delta = ((p.speed - 1) * 100).round();
      request.body =
          '<speak version="1.0" xml:lang="zh-CN"><voice name="${xml(p.voice)}"><prosody rate="${delta >= 0 ? '+' : ''}$delta%">${xml(text)}</prosody></voice></speak>';
    case SpeechProvider.custom:
      final headers = jsonDecode(p.headers) as Map;
      request.headers.addAll(
        headers.map((k, v) => MapEntry('$k', substitute(v as String))),
      );
      if (p.method == 'POST')
        request.body = jsonEncode(template(jsonDecode(p.body)));
  }
  return request;
}

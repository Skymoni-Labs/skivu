import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'speech_recognition_settings.dart';

class RecognitionUpload {
  http.Client? _client;
  void cancel() {
    _client?.close();
    _client = null;
  }

  Future<String> transcribe(RecognitionProfile profile, String path) async {
    profile.validate();
    final client = _client = http.Client();
    try {
      final request = await _request(profile, path);
      Future<String> send() async {
        final response = await client.send(request);
        final body = await response.stream.bytesToString();
        if (response.statusCode < 200 || response.statusCode >= 300) {
          // Never include credentials, audio or request bodies in diagnostics.
          throw FormatException(
            '识别服务返回 HTTP ${response.statusCode}，请检查服务地址、密钥、模型及音频格式。',
          );
        }
        Object? value = body;
        if (profile.responsePath.trim().isNotEmpty) {
          try {
            value = jsonDecode(body);
            for (final key in profile.responsePath.split('.')) {
              value = value is Map
                  ? value[key]
                  : value is List
                  ? value[int.parse(key)]
                  : null;
            }
          } catch (_) {
            throw const FormatException('识别服务响应无法解析，请检查文字字段路径。');
          }
        }
        if (value is! String || value.trim().isEmpty) {
          throw const FormatException('识别服务没有返回文字，请检查录音和文字字段路径。');
        }
        return value.trim();
      }

      final result = send();
      return profile.timeoutSeconds == 0
          ? await result
          : await result.timeout(Duration(seconds: profile.timeoutSeconds));
    } on SocketException {
      throw const FormatException('无法连接识别服务，请检查网络和服务地址。');
    } finally {
      client.close();
      if (identical(_client, client)) _client = null;
    }
  }

  Future<http.BaseRequest> _request(RecognitionProfile p, String path) async {
    Object? expand(Object? value) {
      if (value is String)
        return value
            .replaceAll('{model}', p.model)
            .replaceAll(
              '{language}',
              p.provider == RecognitionProvider.openai
                  ? p.language.split('-').first
                  : p.language,
            );
      if (value is Map)
        return value.map((k, v) => MapEntry(k.toString(), expand(v)));
      if (value is List) return value.map(expand).toList();
      return value;
    }

    final fields = Map<String, dynamic>.from(
      expand(jsonDecode(p.fields)) as Map,
    );
    final uri = Uri.parse(p.endpoint.trim());
    final http.BaseRequest request;
    if (p.transport == 'multipart') {
      final multipart = http.MultipartRequest('POST', uri);
      fields.forEach((k, v) {
        if (v != null && v != '')
          multipart.fields[k] = v is String ? v : jsonEncode(v);
      });
      multipart.files.add(
        await http.MultipartFile.fromPath(
          p.audioField,
          path,
          filename: 'speech.m4a',
          contentType: MediaType('audio', 'mp4'),
        ),
      );
      request = multipart;
    } else {
      fields[p.audioField] = base64Encode(await File(path).readAsBytes());
      request = http.Request('POST', uri)
        ..headers['Content-Type'] = 'application/json'
        ..body = jsonEncode(fields);
    }
    if (p.apiKey.isNotEmpty)
      request.headers['Authorization'] = 'Bearer ${p.apiKey}';
    request.followRedirects = false;
    request.headers.addAll(
      Map<String, String>.from(jsonDecode(p.headers) as Map),
    );
    return request;
  }
}

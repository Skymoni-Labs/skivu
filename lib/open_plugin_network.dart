// SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'open_plugin_dns.dart'
    if (dart.library.js_interop) 'open_plugin_dns_stub.dart'
    as dns;

class PluginApiError implements Exception {
  const PluginApiError(this.code, this.message);
  final String code, message;
}

bool pluginPrivateHost(String value) {
  final h = value.toLowerCase().replaceFirst(RegExp(r'\.$'), '');
  if (h == 'skymoni.com' ||
      h.endsWith('.skymoni.com') ||
      h == 'localhost' ||
      h.endsWith('.localhost') ||
      h.endsWith('.local') ||
      h.endsWith('.internal') ||
      h.endsWith('.invalid') ||
      !h.contains('.') ||
      h.contains(':'))
    return true;
  final p = h.split('.').map(int.tryParse).toList();
  if (p.length == 4 && p.every((x) => x != null)) {
    final a = p[0]!, b = p[1]!, c = p[2]!;
    return a == 0 ||
        a == 10 ||
        a == 127 ||
        a >= 224 ||
        a == 169 && b == 254 ||
        a == 172 && b >= 16 && b <= 31 ||
        a == 192 && (b == 168 || b == 0 || b == 2) ||
        a == 100 && b >= 64 && b <= 127 ||
        a == 198 && (b == 18 || b == 19 || b == 51 && c == 100) ||
        a == 203 && b == 0 && c == 113;
  }
  return false;
}

bool pluginProtectedHost(String h) =>
    h == 'skymoni.com' ||
    h.endsWith('.skymoni.com') ||
    h == '169.254.169.254' ||
    h == 'metadata.google.internal';

Uri pluginNetworkUri(
  String value,
  List<String> domains, {
  bool allowLocal = false,
}) {
  final u = Uri.tryParse(value);
  if (u == null ||
      !(u.scheme == 'https' || allowLocal && u.scheme == 'http') ||
      u.host.isEmpty ||
      u.userInfo.isNotEmpty ||
      u.hasFragment ||
      u.port < 1 ||
      u.port > 65535 ||
      pluginProtectedHost(
        u.host.toLowerCase().replaceFirst(RegExp(r'\.$'), ''),
      ) ||
      !allowLocal && pluginPrivateHost(u.host) ||
      !domains.any(
        (d) =>
            d == '*' ||
            d == u.host ||
            d.startsWith('*.') && u.host.endsWith(d.substring(1)),
      )) {
    throw const PluginApiError('NETWORK_DENIED', '地址不在获准的公开 HTTPS 域名范围内。');
  }
  return u;
}

class PluginNetwork {
  PluginNetwork({http.Client? client, this.resolve = true})
    : _client = client ?? http.Client();
  final http.Client _client;
  final bool resolve;
  final _active = <http.Client>{};
  bool closed = false;
  Future<Map<String, dynamic>> request(
    Map<String, dynamic> p,
    List<String> domains, {
    bool allowLocal = false,
    Future<Map<String, dynamic>> Function(Stream<List<int>> stream)?
    storeResponse,
  }) async {
    if (closed) throw const PluginApiError('CLOSED', '插件已关闭。');
    final url = p['url'];
    if (url is! String)
      throw const PluginApiError('INVALID_ARGUMENT', '缺少有效的 HTTPS 地址。');
    final uri = pluginNetworkUri(url, domains, allowLocal: allowLocal);
    final method = (p['method'] ?? 'GET').toString().toUpperCase();
    if (![
      'GET',
      'POST',
      'PUT',
      'PATCH',
      'DELETE',
      'HEAD',
      'OPTIONS',
    ].contains(method))
      throw const PluginApiError('INVALID_ARGUMENT', 'HTTP 方法不支持。');
    final r = http.Request(method, uri)..followRedirects = false;
    final headers = p['headers'] ?? {};
    if (headers is! Map)
      throw const PluginApiError('INVALID_ARGUMENT', '请求头不正确。');
    for (final e in headers.entries) {
      if (e.key is! String ||
          e.value is! String ||
          !RegExp(r'^[a-zA-Z0-9!#$%&\x27*+.^_`|~-]+$').hasMatch(e.key) ||
          RegExp(r'[\r\n\x00]').hasMatch(e.value) ||
          [
            'host',
            'connection',
            'content-length',
            'proxy-authorization',
            'proxy-connection',
            'forwarded',
            'x-forwarded-for',
          ].contains((e.key as String).toLowerCase()))
        throw const PluginApiError('INVALID_ARGUMENT', '不允许的请求头。');
      r.headers[e.key] = e.value;
    }
    if (p['body'] != null && p['bodyBase64'] != null)
      throw const PluginApiError('INVALID_ARGUMENT', '只能提供一种请求正文。');
    if (p['body'] is String) r.body = p['body'];
    if (p['bodyBase64'] is String) r.bodyBytes = base64Decode(p['bodyBase64']);
    final transport = resolve
        ? await dns.publicClient(
            uri.host,
            scheme: uri.scheme,
            port: uri.port,
            allowLocal: allowLocal,
          )
        : _client;
    _active.add(transport);
    try {
      if (closed) throw const PluginApiError('CLOSED', '插件已关闭。');
      final timeout = p['timeoutSeconds'] as int? ?? 0;
      if (timeout < 0)
        throw const PluginApiError('INVALID_ARGUMENT', '超时不能为负数，0不设置应用时限。');
      final response = await (timeout > 0
          ? transport.send(r).timeout(Duration(seconds: timeout))
          : transport.send(r));
      final metadata = <String, dynamic>{
        'status': response.statusCode,
        'headers': response.headers,
        'mime': response.headers['content-type'] ?? 'application/octet-stream',
      };
      if (storeResponse != null)
        return {
          ...metadata,
          'file': await storeResponse(response.stream),
          'bodyInline': false,
        };
      final bytes = <int>[];
      await for (final chunk
          in timeout > 0
              ? response.stream.timeout(Duration(seconds: timeout))
              : response.stream) {
        bytes.addAll(chunk);
      }
      if (closed) throw const PluginApiError('CLOSED', '插件已关闭。');
      return {
        'status': response.statusCode,
        'headers': {for (final e in response.headers.entries) e.key: e.value},
        'mime': response.headers['content-type'] ?? 'application/octet-stream',
        if (p['responseType'] == 'base64')
          'base64': base64Encode(bytes)
        else
          'body': utf8.decode(bytes, allowMalformed: true),
      };
    } on PluginApiError {
      rethrow;
    } catch (_) {
      throw const PluginApiError('NETWORK_FAILED', '插件的外部网络请求未完成。');
    } finally {
      _active.remove(transport);
      if (resolve) transport.close();
    }
  }

  void close() {
    closed = true;
    for (final c in _active) c.close();
    _client.close();
  }
}

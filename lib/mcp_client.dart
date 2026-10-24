// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'extension_market.dart';

class McpFailure implements Exception {
  const McpFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

class McpConnection {
  const McpConnection(this.endpoint, {this.token = ''});
  final String endpoint, token;
}

/// Tokens are stored separately from extension packages, model keys and backups.
class McpConnectionStore {
  static const _secure = FlutterSecureStorage();
  static String _key(String id) => 'skivu.mcp.token.$id';
  Future<McpConnection?> load(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final endpoint = prefs.getString('skivu.mcp.endpoint.$id');
    if (endpoint == null) return null;
    validateMcpEndpoint(endpoint);
    return McpConnection(
      endpoint,
      token: await _secure.read(key: _key(id)) ?? '',
    );
  }

  Future<void> save(String id, McpConnection value) async {
    validateMcpEndpoint(value.endpoint);
    _validateToken(value.token);
    if (value.token.isEmpty) {
      await _secure.delete(key: _key(id));
    } else {
      await _secure.write(key: _key(id), value: value.token);
    }
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString('skivu.mcp.endpoint.$id', value.endpoint)) {
      throw const McpFailure('连接地址未保存，请重试。');
    }
  }

  Future<void> remove(String id) async {
    await _secure.delete(key: _key(id));
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('skivu.mcp.endpoint.$id');
  }
}

void _validateToken(String token) {
  if (token.length > 8192 || RegExp(r'[\x00-\x20\x7f]').hasMatch(token)) {
    throw const McpFailure('密钥格式无效，请移除空格和换行。');
  }
}

class McpTool {
  McpTool(this.name, this.description, this.inputSchema);
  final String name, description;
  final Map<String, dynamic> inputSchema;
  factory McpTool.parse(Object? value) {
    if (value is! Map ||
        value['name'] is! String ||
        !RegExp(r'^[A-Za-z0-9_.-]{1,128}$').hasMatch(value['name']) ||
        value['inputSchema'] is! Map ||
        value['inputSchema']['type'] != 'object' ||
        (value['description'] != null && value['description'] is! String)) {
      throw const McpFailure('服务返回了无效的工具定义。');
    }
    final description = value['description'] as String? ?? '';
    if (description.length > 20000) throw const McpFailure('工具说明过长。');
    return McpTool(
      value['name'],
      description,
      Map<String, dynamic>.from(value['inputSchema']),
    );
  }
}

/// Streamable HTTP MCP. No process execution, redirects, sampling or roots are
/// offered. A tools/call is sent only after the user invokes a selected tool.
class McpClient {
  McpClient(McpConnection connection, {http.Client? client})
    : endpoint = validateMcpEndpoint(connection.endpoint),
      token = connection.token,
      _client = client ?? http.Client() {
    _validateToken(token);
  }
  final Uri endpoint;
  final String token;
  final http.Client _client;
  String? _session, _protocol;
  int _sequence = 0;
  bool _ready = false, _closed = false;
  static const _versions = ['2025-11-25', '2025-06-18', '2025-03-26'];

  Map<String, dynamic> _result(Object? value, int id) {
    if (value is! Map || value['jsonrpc'] != '2.0' || value['id'] != id) {
      throw const McpFailure('MCP 响应与请求不匹配。');
    }
    if (value['error'] != null) {
      // Remote error text can contain a credential echoed by the server.
      throw const McpFailure('MCP 服务拒绝了请求，请检查参数和服务配置。');
    }
    if (value['result'] is! Map) throw const McpFailure('MCP 服务返回格式不正确。');
    return Map<String, dynamic>.from(value['result']);
  }

  Future<Map<String, dynamic>> _post(
    String method,
    Map<String, dynamic>? params, {
    bool notification = false,
  }) async {
    if (_closed) throw const McpFailure('连接已关闭，请重新连接。');
    final id = ++_sequence;
    final body = jsonEncode({
      'jsonrpc': '2.0',
      if (!notification) 'id': id,
      'method': method,
      if (params != null) 'params': params,
    });
    if (utf8.encode(body).length > 512 * 1024)
      throw const McpFailure('工具参数过大。');
    final request = http.Request('POST', endpoint)
      ..followRedirects = false
      ..headers.addAll({
        'Content-Type': 'application/json',
        'Accept': 'application/json, text/event-stream',
        if (token.isNotEmpty) 'Authorization': 'Bearer $token',
        if (_session != null) 'Mcp-Session-Id': _session!,
        if (_protocol != null) 'MCP-Protocol-Version': _protocol!,
      })
      ..body = body;
    try {
      final response = await _client
          .send(request)
          .timeout(const Duration(seconds: 25));
      return await _read(
        response,
        id,
        notification,
      ).timeout(const Duration(seconds: 60));
    } on TimeoutException {
      close();
      throw const McpFailure('MCP 请求超时，请重新连接。');
    } on McpFailure {
      rethrow;
    } catch (_) {
      throw const McpFailure('MCP 请求未完成，请检查网络或重新连接。');
    }
  }

  Future<Map<String, dynamic>> _read(
    http.StreamedResponse response,
    int id,
    bool notification,
  ) async {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await response.stream.listen((_) {}).cancel();
      if (response.statusCode == 401 || response.statusCode == 403)
        throw const McpFailure('MCP 服务需要有效的访问密钥。');
      if (response.statusCode == 404)
        throw const McpFailure('地址或会话已失效，请检查地址后重新连接。');
      throw McpFailure('MCP 服务返回 HTTP ${response.statusCode}。');
    }
    final session = response.headers['mcp-session-id'];
    if (session != null) {
      if (session.isEmpty ||
          session.length > 512 ||
          RegExp(r'[^\x21-\x7e]').hasMatch(session)) {
        await response.stream.listen((_) {}).cancel();
        throw const McpFailure('MCP 会话标识无效。');
      }
      if (_session != null && _session != session) {
        await response.stream.listen((_) {}).cancel();
        throw const McpFailure('MCP 会话意外变化，请重新连接。');
      }
      _session = session;
    }
    if (notification && response.statusCode == 202) {
      await response.stream.listen((_) {}).cancel();
      return {};
    }
    final contentType = response.headers['content-type']
        ?.split(';')
        .first
        .trim();
    var total = 0;
    final stream = response.stream
        .map((chunk) {
          total += chunk.length;
          if (total > 4 * 1024 * 1024) throw const McpFailure('MCP 响应过大。');
          return chunk;
        })
        .timeout(const Duration(seconds: 45));
    if (contentType == 'application/json') {
      final bytes = <int>[];
      await for (final chunk in stream) {
        bytes.addAll(chunk);
      }
      if (notification) return {};
      return _result(jsonDecode(utf8.decode(bytes)), id);
    }
    if (contentType == 'text/event-stream' && !notification) {
      final data = <String>[];
      await for (final line
          in stream.transform(utf8.decoder).transform(const LineSplitter())) {
        if (line.isEmpty && data.isNotEmpty) {
          final event = data.join('\n');
          data.clear();
          if (event.trim().isEmpty) continue;
          final value = jsonDecode(event);
          if (value is Map &&
              value['id'] == id &&
              (value.containsKey('result') || value.containsKey('error'))) {
            return _result(value, id);
          }
          // Notifications are informational. No server-initiated capability is enabled.
        } else if (line.startsWith('data:')) {
          data.add(line.substring(5).replaceFirst(RegExp(r'^ '), ''));
        }
      }
      throw const McpFailure('MCP 事件流已断开，未收到完整结果。');
    }
    await response.stream.listen((_) {}).cancel();
    throw const McpFailure('服务未提供支持的 MCP HTTP 响应。');
  }

  Future<void> initialize() async {
    final result = await _post('initialize', {
      'protocolVersion': _versions.first,
      'capabilities': <String, dynamic>{},
      'clientInfo': {'name': 'Skivu', 'version': '1.0.0'},
    });
    if (!_versions.contains(result['protocolVersion']) ||
        result['capabilities'] is! Map ||
        result['capabilities']['tools'] is! Map) {
      throw const McpFailure('此服务没有提供受支持的 MCP 工具接口。');
    }
    _protocol = result['protocolVersion'];
    await _post('notifications/initialized', null, notification: true);
    _ready = true;
  }

  Future<List<McpTool>> listTools() async {
    if (!_ready) throw const McpFailure('请先连接 MCP 服务。');
    final tools = <McpTool>[];
    final cursors = <String>{};
    String? cursor;
    do {
      final result = await _post('tools/list', {
        if (cursor != null) 'cursor': cursor,
      });
      if (result['tools'] is! List) throw const McpFailure('MCP 工具列表无效。');
      tools.addAll((result['tools'] as List).map(McpTool.parse));
      if (tools.length > 1000 ||
          tools.map((item) => item.name).toSet().length != tools.length) {
        throw const McpFailure('MCP 工具列表过大或包含重复项目。');
      }
      final next = result['nextCursor'];
      if (next != null &&
          (next is! String ||
              next.isEmpty ||
              next.length > 4000 ||
              !cursors.add(next))) {
        throw const McpFailure('MCP 工具分页无效。');
      }
      cursor = next;
    } while (cursor != null);
    return tools;
  }

  Future<Map<String, dynamic>> callTool(
    McpTool tool,
    Map<String, dynamic> arguments,
  ) async {
    if (!_ready) throw const McpFailure('请先连接 MCP 服务。');
    return _post('tools/call', {'name': tool.name, 'arguments': arguments});
  }

  void close() {
    _closed = true;
    _ready = false;
    _client.close();
  }
}

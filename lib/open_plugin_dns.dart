// SPDX-License-Identifier: GPL-3.0-only
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'open_plugin_network.dart'
    show pluginPrivateHost, pluginProtectedHost, PluginApiError;

bool pluginExternalAddressPublic(InternetAddress address) {
  if (address.isLoopback || address.isLinkLocal || address.isMulticast)
    return false;
  if (address.type == InternetAddressType.IPv4)
    return !pluginPrivateHost(address.address);
  final words = address.address.toLowerCase().split(':');
  final first = int.tryParse(words[0], radix: 16) ?? 0,
      second = int.tryParse(words.length > 1 ? words[1] : '0', radix: 16) ?? 0;
  return !address.address.contains('.') &&
      first >= 0x2000 &&
      first <= 0x3fff &&
      first != 0x2002 &&
      !(first == 0x2001 && (second < 0x0200 || second == 0x0db8));
}

Future<void> publicExternalTarget(String host) async {
  try {
    final addresses = await InternetAddress.lookup(
      host,
    ).timeout(const Duration(seconds: 12));

    if (addresses.isEmpty ||
        addresses.any((address) => !pluginExternalAddressPublic(address)))
      throw const PluginApiError('NETWORK_DENIED', '外部链接不能指向内部地址。');
    final protected = await InternetAddress.lookup(
      'skymoni.com',
    ).timeout(const Duration(seconds: 12));
    if (protected.isEmpty ||
        addresses.any((a) => protected.any((p) => p.address == a.address)))
      throw const PluginApiError('NETWORK_DENIED', '宿主服务器不向插件开放。');
  } on PluginApiError {
    rethrow;
  } catch (_) {
    throw const PluginApiError('NETWORK_FAILED', '外部链接域名解析未完成。');
  }
}

Future<ConnectionTask<Socket>> pluginPinnedConnection(
  Uri uri,
  InternetAddress address, {
  SecurityContext? securityContext,
}) async {
  final task = await Socket.startConnect(address, uri.port);
  Socket? connected;
  final socket = task.socket.then<Socket>((raw) async {
    connected = raw;
    if (uri.scheme != 'https') return raw;
    try {
      final secure = await SecureSocket.secure(
        raw,
        host: uri.host,
        context: securityContext,
      );
      connected = secure;
      return secure;
    } catch (_) {
      raw.destroy();
      rethrow;
    }
  });
  return ConnectionTask.fromSocket(socket, () {
    task.cancel();
    connected?.destroy();
  });
}

Future<http.Client> publicClient(
  String host, {
  required String scheme,
  required int port,
  bool allowLocal = false,
}) async {
  try {
    final addresses = await InternetAddress.lookup(
      host,
    ).timeout(const Duration(seconds: 12));
    if (addresses.isEmpty)
      throw const PluginApiError('NETWORK_DENIED', '地址无法解析。');
    // IPv4 transport only: reject private/loopback results and mapped IPv6 too.
    final v4 = addresses
        .where((a) => a.type == InternetAddressType.IPv4)
        .toList();
    if (v4.isEmpty ||
        addresses.any(
          (a) =>
              (!allowLocal && a.isLoopback) ||
              a.isLinkLocal ||
              a.isMulticast ||
              a.type == InternetAddressType.IPv4 &&
                  ((!allowLocal && pluginPrivateHost(a.address)) ||
                      pluginProtectedHost(a.address)),
        ))
      throw const PluginApiError('NETWORK_DENIED', '插件不能访问内部地址。');
    final protected = await InternetAddress.lookup(
      'skymoni.com',
    ).timeout(const Duration(seconds: 12));
    if (protected.isEmpty ||
        v4.any((a) => protected.any((p) => p.address == a.address)))
      throw const PluginApiError('NETWORK_DENIED', '宿主服务器不向插件开放。');
    final pinned = v4.first;
    final client = HttpClient()..findProxy = ((_) => 'DIRECT');
    // Pin the already validated socket address. TLS still validates the original
    // URL host and SNI. No second DNS lookup or environment proxy can redirect
    // an authorized public request into host/private infrastructure.
    client.connectionFactory = (uri, proxyHost, proxyPort) {
      if (uri.host != host || uri.scheme != scheme || uri.port != port)
        throw const PluginApiError('NETWORK_DENIED', '连接目标发生变化。');
      return pluginPinnedConnection(uri, pinned);
    };
    return IOClient(client);
  } on PluginApiError {
    rethrow;
  } catch (_) {
    throw const PluginApiError('NETWORK_FAILED', '域名解析未完成。');
  }
}

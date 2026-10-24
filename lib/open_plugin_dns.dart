// SPDX-License-Identifier: GPL-3.0-only
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'open_plugin_network.dart'
    show pluginPrivateHost, pluginProtectedHost, PluginApiError;

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
      return Socket.startConnect(pinned, uri.port);
    };
    return IOClient(client);
  } on PluginApiError {
    rethrow;
  } catch (_) {
    throw const PluginApiError('NETWORK_FAILED', '域名解析未完成。');
  }
}

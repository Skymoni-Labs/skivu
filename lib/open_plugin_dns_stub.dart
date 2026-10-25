// SPDX-License-Identifier: GPL-3.0-only
import 'open_plugin_network.dart' show PluginApiError;
import 'package:http/http.dart' as http;

Future<void> publicExternalTarget(String host) async =>
    throw const PluginApiError('UNSUPPORTED', '此平台不支持打开外部软件。');

Future<http.Client> publicClient(
  String host, {
  required String scheme,
  required int port,
  bool allowLocal = false,
}) async => throw const PluginApiError('UNSUPPORTED', '此平台不支持插件网络代理。');

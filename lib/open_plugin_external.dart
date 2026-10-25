// SPDX-License-Identifier: GPL-3.0-only
import 'package:flutter/services.dart';
import 'open_plugin_network.dart';
import 'open_plugin_dns.dart'
    if (dart.library.js_interop) 'open_plugin_dns_stub.dart'
    as dns;

Uri pluginExternalUri(Object? value) {
  if (value is! String ||
      value.isEmpty ||
      value.length > 8192 ||
      RegExp(r'[\x00-\x20\x7f\\]').hasMatch(value)) {
    throw const PluginApiError('INVALID_ARGUMENT', '请提供有效的公开 HTTPS 地址。');
  }
  return pluginNetworkUri(value, const ['*']);
}

Future<void> checkPluginExternalTarget(Uri uri) async {
  await dns.publicExternalTarget(uri.host);
}

/// The external browser/app owns subsequent navigation and authentication.
/// accepted means Android accepted ACTION_VIEW, never a completed business action.
Future<Map<String, String>> openPluginExternal(
  Map<String, dynamic> params, {
  required Future<bool> Function(Uri) confirm,
  required void Function() check,
  Future<void> Function(Uri) validateTarget = checkPluginExternalTarget,
  Future<String?> Function(Uri)? launch,
}) async {
  if (params.length != 1 || !params.containsKey('url')) {
    throw const PluginApiError('INVALID_ARGUMENT', '打开外部链接只接受 url。');
  }
  final uri = pluginExternalUri(params['url']);
  await validateTarget(uri);
  check();
  if (!await confirm(uri)) return {'status': 'cancelled'};
  check();
  await validateTarget(uri);
  check();
  try {
    final status =
        await (launch ??
            ((uri) => const MethodChannel(
              'skivu/open_plugin_external',
            ).invokeMethod<String>('open', {'url': uri.toString()})))(uri);
    if (!['accepted', 'not_available'].contains(status)) {
      throw const PluginApiError('EXTERNAL_FAILED', '系统未返回有效的打开结果。');
    }
    return {'status': status!};
  } on MissingPluginException {
    return {'status': 'not_available'};
  } on PlatformException {
    throw const PluginApiError('EXTERNAL_FAILED', '系统未能打开该链接。');
  }
}

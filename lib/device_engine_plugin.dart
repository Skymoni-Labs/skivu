import 'dart:convert';
import 'dart:async';
import 'package:crypto/crypto.dart';
import 'device_engine.dart';
import 'device_tool_catalog.dart';
import 'open_plugin.dart';
import 'open_plugin_network.dart';

String devicePluginOwner(OpenPluginRecord record) =>
    'plugin:${sha256.convert(utf8.encode('${record.manifest.id}\u0000${record.package.digest}'))}';

/// Binds outstanding native requests to the actual page/runtime lifetime.
class DeviceEngineScope {
  DeviceEngineScope({DeviceEngine? engine}) : engine = engine ?? deviceEngine;
  final DeviceEngine engine;
  final calls = <Object, (String, String)>{};
  bool closed = false;
  Future<List<Map<String, dynamic>>>? _shutdown;
  void close() {
    unawaited(closeAndWait());
  }

  Future<List<Map<String, dynamic>>> closeAndWait() => _shutdown ??= _close();
  Future<List<Map<String, dynamic>>> _close() async {
    closed = true;
    return Future.wait([
      for (final entry in calls.entries.toList())
        engine
            .cancelRequest(entry.value.$1, entry.value.$2)
            .catchError((_) => <String, dynamic>{'outcome': 'unknown'}),
    ]);
  }

  Future<Object?> call(
    OpenPluginRegistry registry,
    OpenPluginRecord record,
    String method,
    Map<String, dynamic> params, {
    void Function()? checkRuntime,
  }) async {
    void check() {
      if (closed) throw const PluginApiError('CLOSED', '设备会话已关闭。');
      checkRuntime?.call();
    }

    check();
    if (method == 'device.engine.cancel') {
      if (params.length != 1 || params['requestId'] is! String) {
        throw const PluginApiError('INVALID_ARGUMENT', '取消请求编号无效。');
      }
      final owned = calls.values
          .where((call) => call.$2 == params['requestId'])
          .firstOrNull;
      return owned == null
          ? {'outcome': 'cancelled', 'summary': '本会话没有这个正在执行的请求，已生效的操作请核对。'}
          : engine.cancelRequest(owned.$1, owned.$2);
    }
    final normalized = Map<String, dynamic>.from(params);
    final id = method == 'device.engine.invoke'
        ? normalized.putIfAbsent(
                'requestId',
                () => 'scope_${DateTime.now().microsecondsSinceEpoch}',
              )
              as String
        : null;
    final ticket = Object();
    if (id != null) calls[ticket] = (devicePluginOwner(record), id);
    try {
      return await deviceEnginePluginCall(
        registry,
        record,
        method,
        normalized,
        engine: engine,
        checkRuntime: check,
      );
    } finally {
      calls.remove(ticket);
    }
  }
}

/// Called only after the existing host bridge has checked the active runtime.
/// A plugin cannot select the owner or bypass its manifest/host permissions.
Future<Object?> deviceEnginePluginCall(
  OpenPluginRegistry registry,
  OpenPluginRecord record,
  String method,
  Map<String, dynamic> params, {
  DeviceEngine? engine,
  void Function()? checkRuntime,
}) async {
  void check() {
    checkRuntime?.call();
    if (registry.records[record.manifest.id] != record || !record.authorized) {
      throw const PluginApiError('CLOSED', '插件已关闭或授权已变化。');
    }
  }

  check();
  final host = engine ?? deviceEngine;
  if (method == 'device.engine.catalog') {
    if (params.isNotEmpty ||
        !record.manifest.permissions.contains('device.observe')) {
      throw const PluginApiError('PERMISSION_DENIED', '没有读取设备能力的授权。');
    }
    final entries = await host.catalog();
    check();
    return {
      'version': 1,
      'tools': entries
          .where(
            (entry) =>
                record.manifest.permissions.contains(entry['permission']),
          )
          .toList(),
    };
  }
  if (method != 'device.engine.invoke') {
    throw const PluginApiError('METHOD_NOT_FOUND', '设备引擎方法不存在。');
  }
  if (params.keys.any(
        (key) => !{'tool', 'arguments', 'requestId'}.contains(key),
      ) ||
      params['tool'] is! String ||
      params['arguments'] is! Map ||
      (params.containsKey('requestId') && params['requestId'] is! String)) {
    throw const PluginApiError('INVALID_ARGUMENT', '设备调用参数无效。');
  }
  final definition = deviceTool(params['tool']);
  if (!record.manifest.permissions.contains(definition.permission)) {
    throw const PluginApiError('PERMISSION_DENIED', '插件没有此设备能力的授权。');
  }
  final owner = devicePluginOwner(record);
  final requestId =
      params['requestId'] as String? ??
      'plugin_${DateTime.now().microsecondsSinceEpoch}';
  void watch() {
    try {
      check();
    } catch (_) {
      unawaited(
        host
            .cancelRequest(owner, requestId)
            .catchError((_) => <String, dynamic>{}),
      );
    }
  }

  registry.addListener(watch);
  try {
    final receipt = await host.invoke(
      definition.id,
      Map<String, dynamic>.from(params['arguments']),
      owner: owner,
      requestId: requestId,
    );
    check();
    return receipt.data;
  } finally {
    registry.removeListener(watch);
  }
}

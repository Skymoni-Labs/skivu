// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'open_plugin.dart';
import 'open_plugin_bridge.dart';
import 'open_plugin_network.dart';

typedef CompanionRunner =
    Future<Object?> Function(
      OpenPluginRecord record,
      Map<String, dynamic> tool,
      Map<String, dynamic> arguments,
      Map<String, dynamic> context,
      void Function() check,
    );

/// A transient instance. No UI route, timers, model access or retained WebView.
class OpenPluginRuntime with WidgetsBindingObserver {
  OpenPluginRuntime({
    required this.registry,
    required this.record,
    required this.context,
    required this.effect,
    required this.checkContext,
    required this.host,
  });
  final OpenPluginRegistry registry;
  final OpenPluginRecord record;
  final Map<String, dynamic> context;
  final String effect;
  final void Function() checkContext;
  final PluginHostCall host;
  static int _serial = 0;
  static const _platform = MethodChannel('skivu/open_plugin_runtime');
  late final int id = --_serial;
  late final MethodChannel channel = MethodChannel('skivu/open_plugin/$id');
  late final OpenPluginBridge bridge = OpenPluginBridge(
    registry: registry,
    record: record,
    host: hostCall,
    guard: checkContext,
  );
  final _ready = Completer<void>(), _done = Completer<Object?>();
  bool closed = false;
  void check() {
    if (closed) throw const PluginApiError('CANCELLED', '本轮工具已结束。');
    checkContext();
    bridge.check();
  }

  void cancel() {
    closed = true;
    bridge.close();
    if (!_ready.isCompleted)
      _ready.completeError(const PluginApiError('CANCELLED', '任务已暂停。'));
    if (!_done.isCompleted)
      _done.completeError(const PluginApiError('CANCELLED', '任务已暂停。'));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached)
      cancel();
  }

  Future<Object?> hostCall(String method, Map<String, dynamic> params) async {
    check();
    if (method == 'context.get') return context;
    if (method == 'ui.toast') return true;
    if (method == 'ui.openExternal' && effect == 'external')
      return host(method, params);
    throw const PluginApiError(
      'PERMISSION_DENIED',
      '聊天工具不提供界面、模型、聊天写入或角色修改能力。',
    );
  }

  Future<Object?> run(String tool, Map<String, dynamic> args) async {
    WidgetsBinding.instance.addObserver(this);
    // Attach error listeners before a cancellation can complete either future.
    final ready = _ready.future;
    final done = _done.future;
    unawaited(ready.catchError((Object _) {}));
    unawaited(done.catchError((Object _) => null));
    channel.setMethodCallHandler((call) async {
      if (call.method != 'request') return null;
      try {
        check();
        final raw = jsonDecode(call.arguments as String) as Map;
        final method = raw['method'];
        if (method == 'runtime.ready') {
          if (!_ready.isCompleted) _ready.complete();
          return {'ok': true, 'result': true};
        }
        if (method == 'runtime.complete') {
          final result = raw['params'];
          if (result is! Map ||
              utf8.encode(jsonEncode(result)).length > 32768 ||
              !result.containsKey('result'))
            throw const PluginApiError('INVALID_ARGUMENT', '工具结果超过限制。');
          if (!_done.isCompleted) _done.complete(result['result']);
          return {'ok': true, 'result': true};
        }
        const reads = {
          'host.info',
          'context.get',
          'storage.get',
          'storage.keys',
          'fs.read',
          'fs.list',
          'secrets.get',
          'network.request',
          'https.request',
          'ui.toast',
        };
        const writes = {'storage.compareAndSet', 'fs.write', 'fs.remove'};
        if (!reads.contains(method) &&
            !(effect == 'write' && writes.contains(method)) &&
            !(effect == 'external' && method == 'ui.openExternal'))
          throw const PluginApiError('PERMISSION_DENIED', '该工具未声明这种操作。');
        if ({'network.request', 'https.request'}.contains(method) &&
            !{
              'GET',
              'HEAD',
            }.contains((raw['params'] as Map?)?['method'] ?? 'GET'))
          throw const PluginApiError(
            'PERMISSION_DENIED',
            '随聊工具仅支持只读网络请求，外部操作须在前台单独授权。',
          );
        return await bridge.dispatch(raw);
      } on PluginApiError catch (e) {
        return {
          'ok': false,
          'error': {'code': e.code, 'message': e.message},
        };
      } catch (_) {
        return {
          'ok': false,
          'error': {'code': 'TOOL_FAILED', 'message': '插件工具请求未完成。'},
        };
      }
    });
    try {
      check();
      await _platform.invokeMethod('create', {
        'id': id,
        'entry': record.manifest.companion!['entry'],
        'digest': record.package.digest,
        'files': record.package.files,
      });
      await ready.timeout(const Duration(seconds: 10));
      check();
      await channel.invokeMethod('event', {
        'name': 'companion.invoke',
        'detail': {'tool': tool, 'arguments': args},
      });
      final result = await done.timeout(const Duration(seconds: 45));
      check();
      return result;
    } finally {
      closed = true;
      bridge.close();
      WidgetsBinding.instance.removeObserver(this);
      channel.setMethodCallHandler(null);
      try {
        await _platform.invokeMethod('dispose', {'id': id});
      } catch (_) {}
    }
  }
}

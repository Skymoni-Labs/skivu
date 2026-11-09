// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'open_plugin.dart';
import 'open_plugin_bridge.dart';
import 'open_plugin_network.dart';
import 'device_tool_catalog.dart';
import 'open_plugin_lab.dart';

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
    this.assistant = false,
    this.onCancel,
  });
  final OpenPluginRegistry registry;
  final OpenPluginRecord record;
  final Map<String, dynamic> context;
  final String effect;
  final void Function() checkContext;
  final PluginHostCall host;
  final bool assistant;
  final VoidCallback? onCancel;
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
    onCancel?.call();
    closed = true;
    bridge.close();
    if (!_ready.isCompleted)
      _ready.completeError(const PluginApiError('CANCELLED', '任务已暂停。'));
    if (!_done.isCompleted)
      _done.completeError(const PluginApiError('CANCELLED', '任务已暂停。'));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!assistant &&
        (state == AppLifecycleState.paused ||
            state == AppLifecycleState.detached))
      cancel();
  }

  Future<Object?> hostCall(String method, Map<String, dynamic> params) async {
    check();
    if (method == 'context.get') return context;
    if (method == 'ui.toast') return true;
    if (assistant && method == 'lab.call') {
      final value = await invokePluginLab(
        record,
        params,
        assistant: true,
        readOnly: effect == 'read',
        callId: context['callId'] as String?,
      );
      check();
      return value;
    }
    if (assistant && method.startsWith('device.engine.'))
      return host(method, params);
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
      if (call.method == 'failure') {
        final error = PluginApiError(
          'RUNTIME_FAILED',
          call.arguments.toString(),
        );
        if (!_ready.isCompleted) _ready.completeError(error);
        if (!_done.isCompleted) _done.completeError(error);
        return null;
      }
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
          if (result is! Map || !result.containsKey('result'))
            throw const PluginApiError('INVALID_ARGUMENT', '工具结果格式无效。');
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
          'lab.call',
        };
        const writes = {'storage.compareAndSet', 'fs.write', 'fs.remove'};
        var allowedDeviceCall = false;
        if (assistant && method == 'device.engine.invoke') {
          final params = raw['params'];
          if (params is Map && params['tool'] is String) {
            final definition = deviceTool(params['tool'] as String);
            allowedDeviceCall =
                definition.effect == 'read' || effect == 'external';
          }
        }
        if (!reads.contains(method) &&
            !(assistant &&
                {
                  'device.engine.catalog',
                  'device.engine.cancel',
                }.contains(method)) &&
            !allowedDeviceCall &&
            !({'write', 'external'}.contains(effect) &&
                writes.contains(method)) &&
            !(effect == 'external' && method == 'ui.openExternal'))
          throw const PluginApiError('PERMISSION_DENIED', '该工具未声明这种操作。');
        if (effect != 'external' &&
            {'network.request', 'https.request'}.contains(method) &&
            !{
              'GET',
              'HEAD',
            }.contains((raw['params'] as Map?)?['method'] ?? 'GET'))
          throw const PluginApiError(
            'PERMISSION_DENIED',
            '当前工具声明为只读；修改外部服务需要已授权且声明external的工具。',
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
        'assistant': assistant,
        'id': id,
        'entry': (assistant
            ? record.manifest.assistantTools
            : record.manifest.companion)!['entry'],
        'digest': record.package.digest,
        'files': record.package.files,
      });
      await ready;
      check();
      await channel.invokeMethod('event', {
        'name': 'companion.invoke',
        'detail': {'tool': tool, 'arguments': args},
      });
      final result = await done;
      check();
      return result;
    } finally {
      onCancel?.call();
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

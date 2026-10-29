// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:convert';

import 'chat_api.dart';
import 'local_runtime_device_gateway.dart';
import 'local_runtime_model_gateway.dart';
import 'open_plugin_bridge.dart';

/// Host-side lifecycle coordinator for independently installed runtimes.
/// Transport authentication and Android process management remain the caller's
/// responsibility. No plugin-specific identifier is built into this class.
class LocalRuntimeSessions {
  Future<void> _tail = Future<void>.value();
  _RuntimeSession? _active;
  int _nextGeneration = 0;
  bool _disposed = false;

  /// The device host uses this after consent and before each task step.
  /// A stale generation must never inherit a later runtime's authority.
  bool isActive(int generation) =>
      !_disposed && _active?.id == generation && _active?.closed == false;

  Future<T> _serial<T>(Future<T> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  /// Each opening receives fresh brokers. A delayed close from a previous
  /// generation cannot close or issue operations on the new generation.
  Future<int> open({
    required OpenPluginBridge bridge,
    required Future<bool> Function() confirmModel,
    required AgentChatSession Function() newModelSession,
  }) => _serial(() async {
    if (_disposed) {
      bridge.close();
      throw StateError('Runtime coordinator disposed');
    }
    final previous = _active;
    _active = null;
    await previous?.close();
    try {
      bridge.check();
    } catch (_) {
      bridge.close();
      rethrow;
    }
    final id = ++_nextGeneration;
    _active = _RuntimeSession(
      id,
      bridge,
      LocalRuntimeModelGateway(
        bridge: bridge,
        confirm: confirmModel,
        newSession: newModelSession,
      ),
      LocalRuntimeDeviceGateway(bridge),
    );
    return id;
  });

  Future<String> handle(int generation, String kind, String frame) async {
    final session = _active;
    if (session == null || session.id != generation || session.closed) {
      return _closed();
    }
    final String result;
    if (kind == 'model') {
      result = await session.model.handle(frame);
    } else if (kind == 'device') {
      result = await session.device.handle(frame);
    } else {
      return jsonEncode({
        'id': '',
        'ok': false,
        'error': {'code': 'METHOD_NOT_FOUND', 'message': '运行能力不受支持。'},
      });
    }
    return identical(_active, session) && !session.closed ? result : _closed();
  }

  Future<void> close(int generation) => _serial(() async {
    final current = _active;
    if (current == null || current.id != generation) return;
    _active = null;
    await current.close();
  });

  Future<void> dispose() => _serial(() async {
    _disposed = true;
    final current = _active;
    _active = null;
    await current?.close();
  });

  String _closed() => jsonEncode({
    'id': '',
    'ok': false,
    'error': {'code': 'CLOSED', 'message': '运行环境已关闭。'},
  });
}

class _RuntimeSession {
  _RuntimeSession(this.id, this.bridge, this.model, this.device);
  final int id;
  final OpenPluginBridge bridge;
  final LocalRuntimeModelGateway model;
  final LocalRuntimeDeviceGateway device;
  bool closed = false;

  Future<void> close() async {
    if (closed) return;
    closed = true;
    model.close();
    try {
      await device.close();
    } finally {
      // The runtime is already closed to new calls. An in-flight start can
      // still return a task ID; retain the bridge until it requests cancel.
      unawaited(device.whenIdle().whenComplete(bridge.close));
    }
  }
}

// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'open_plugin_bridge.dart';

/// Validated device-task requests from a separately isolated local runtime.
/// The existing plugin bridge enforces permission, ownership and revocation;
/// this gateway cannot invoke other host APIs or reveal host credentials.
class LocalRuntimeDeviceGateway {
  LocalRuntimeDeviceGateway(this.bridge);
  final OpenPluginBridge bridge;
  final _seen = <String>{};
  final _ownedTasks = <String>{};
  bool _closed = false;
  int _inFlight = 0;
  Completer<void>? _idle;

  /// A late start may still need the bridge to cancel the resulting task.
  Future<void> whenIdle() {
    if (_inFlight == 0) return Future<void>.value();
    return (_idle ??= Completer<void>()).future;
  }

  static const methods = <String>{
    'device.discover',
    'device.connect',
    'device.status',
    'device.apps',
    'device.openCompanion',
    'device.disconnect',
    'agent.tasks.start',
    'agent.tasks.get',
    'agent.tasks.cancel',
  };
  static const maxFrameBytes = 64 * 1024;
  static const maxQueuedFrames = 8;

  Future<void> _cancelTask(String taskId) async {
    // The bridge enforces the original plugin's grant and task ownership.
    // A failed cancellation or revoked bridge does not prove the task stopped.
    await bridge.dispatch({
      'id': '0',
      'method': 'agent.tasks.cancel',
      'params': {'taskId': taskId},
    });
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final tasks = _ownedTasks.toList();
    _ownedTasks.clear();
    for (final task in tasks) {
      await _cancelTask(task);
    }
  }

  /// Consume newline-delimited UTF-8 frames from a host-owned local transport.
  /// Sequential dispatch bounds outstanding device operations and preserves
  /// request order. The caller owns connection lifetime and authentication.
  /// A malformed or oversized frame terminates the transport; it is never
  /// passed to the plugin bridge.
  Future<void> serve(
    Stream<List<int>> input,
    Future<void> Function(List<int> bytes) send,
  ) {
    final done = Completer<void>();
    StreamSubscription<List<int>>? subscription;
    var frame = BytesBuilder(copy: false);
    var queued = 0;
    var ended = false;
    Future<void> tail = Future<void>.value();

    void finish([Object? error, StackTrace? stack]) {
      if (ended) return;
      ended = true;
      unawaited(subscription?.cancel());
      unawaited(
        close().whenComplete(() {
          if (error == null) {
            done.complete();
          } else {
            done.completeError(error, stack);
          }
        }),
      );
    }

    void enqueue(List<int> bytes) {
      if (++queued > maxQueuedFrames) {
        finish(const FormatException('Too many queued device frames'));
        return;
      }
      late final String text;
      try {
        text = utf8.decode(bytes);
      } on FormatException catch (error, stack) {
        finish(error, stack);
        return;
      }
      tail = tail
          .then<void>((_) async {
            if (ended) return;
            final reply = await handle(text);
            if (!ended) await send(utf8.encode('$reply\n'));
            queued--;
          })
          .catchError((Object error, StackTrace stack) => finish(error, stack));
    }

    subscription = input.listen(
      (chunk) {
        if (ended) return;
        var start = 0;
        for (var i = 0; i < chunk.length; i++) {
          if (chunk[i] != 10) continue;
          if (frame.length + i - start > maxFrameBytes) {
            finish(const FormatException('Device request frame too large'));
            return;
          }
          frame.add(chunk.sublist(start, i));
          enqueue(frame.takeBytes());
          if (ended) return;
          frame = BytesBuilder(copy: false);
          start = i + 1;
        }
        if (frame.length + chunk.length - start > maxFrameBytes) {
          finish(const FormatException('Device request frame too large'));
          return;
        }
        frame.add(chunk.sublist(start));
      },
      onError: (Object error, StackTrace stack) => finish(error, stack),
      onDone: () => frame.length == 0
          ? finish()
          : finish(const FormatException('Incomplete device request frame')),
    );
    return done.future;
  }

  Future<String> handle(String frame) async {
    String id = '';
    Map<String, dynamic> failure(String code, String message) => {
      'id': id,
      'ok': false,
      'error': {'code': code, 'message': message},
    };
    if (_closed) return jsonEncode(failure('CLOSED', '运行环境已关闭。'));
    _inFlight++;
    try {
      if (utf8.encode(frame).length > maxFrameBytes) {
        return jsonEncode(failure('LIMIT_EXCEEDED', '请求过大。'));
      }
      final raw = jsonDecode(frame);
      if (raw is! Map ||
          raw.length != 3 ||
          raw['id'] is! String ||
          !RegExp(r'^[0-9]{1,16}$').hasMatch(raw['id']) ||
          raw['method'] is! String ||
          raw['params'] is! Map) {
        return jsonEncode(failure('INVALID_ARGUMENT', '请求格式不正确。'));
      }
      id = raw['id'] as String;
      if (_seen.contains(id)) {
        return jsonEncode(failure('DUPLICATE_REQUEST', '请求编号已使用。'));
      }
      if (_seen.length >= 4096) {
        return jsonEncode(failure('LIMIT_EXCEEDED', '请求次数已达上限，请重新连接。'));
      }
      _seen.add(id);
      if (!methods.contains(raw['method'])) {
        return jsonEncode(failure('METHOD_NOT_FOUND', '该本地运行能力尚未开放。'));
      }
      final result = await bridge.dispatch(raw);
      final value = result['result'];
      if (result['ok'] == true && value is Map && value['taskId'] is String) {
        final task = value['taskId'] as String;
        if (raw['method'] == 'agent.tasks.start') {
          if (_closed) {
            await _cancelTask(task);
          } else {
            _ownedTasks.add(task);
          }
        } else if ({
              'agent.tasks.get',
              'agent.tasks.cancel',
            }.contains(raw['method']) &&
            {
              'completed',
              'failed',
              'cancelled',
              'review_required',
            }.contains(value['state'])) {
          _ownedTasks.remove(task);
        }
      }
      if (_closed) return jsonEncode(failure('CLOSED', '运行环境已关闭。'));
      final response = jsonEncode({'id': id, ...result});
      if (utf8.encode(response).length > maxFrameBytes) {
        return jsonEncode(failure('LIMIT_EXCEEDED', '设备响应过大。'));
      }
      return response;
    } on FormatException {
      return jsonEncode(failure('INVALID_ARGUMENT', '请求格式不正确。'));
    } catch (_) {
      return jsonEncode(failure('OPERATION_FAILED', '设备请求未完成。'));
    } finally {
      _inFlight--;
      if (_inFlight == 0) {
        _idle?.complete();
        _idle = null;
      }
    }
  }
}

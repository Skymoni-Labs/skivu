// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'chat_api.dart';
import 'open_plugin_bridge.dart';
import 'open_plugin_network.dart';

/// Broker for an isolated runtime. It requires both the existing
/// ai.generate grant and a live host authorization check on each request.
/// Model selection resolves host catalog IDs; credentials, endpoints and funding
/// remain in the host.
class LocalRuntimeModelGateway {
  LocalRuntimeModelGateway({
    required this.bridge,
    required this.confirm,
    required this.newSession,
    this.listModels,
    this.openSession,
  });

  final OpenPluginBridge bridge;
  final Future<bool> Function() confirm;
  final AgentChatSession Function() newSession;
  final FutureOr<List<Map<String, Object>>> Function()? listModels;
  final Future<AgentChatSession> Function(String? model)? openSession;
  final _seen = <String>{};
  bool _busy = false;
  bool _closed = false;
  AgentChatSession? _activeSession;

  static const maxFrameBytes = 4 * 1024 * 1024;
  static const maxQueuedFrames = 4;

  /// A host-owned transport calls this with already-authenticated bytes.
  /// EOF cancels the active request immediately, even while it is waiting on
  /// the model. Requests queued before disconnect are never dispatched.
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
      close();
      unawaited(subscription?.cancel());
      if (error == null) {
        done.complete();
      } else {
        done.completeError(error, stack);
      }
    }

    void enqueue(List<int> bytes) {
      if (++queued > maxQueuedFrames) {
        finish(const FormatException('Too many queued model frames'));
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
          .then((_) async {
            if (ended) return;
            final response = await handle(text);
            final encoded = utf8.encode(response);
            if (encoded.length > maxFrameBytes) {
              throw const FormatException('Model response frame too large');
            }
            if (!ended) await send([...encoded, 10]);
            queued--;
          })
          .catchError((Object error, StackTrace stack) {
            finish(error, stack);
          });
    }

    subscription = input.listen(
      (chunk) {
        if (ended) return;
        var start = 0;
        for (var i = 0; i < chunk.length; i++) {
          if (chunk[i] != 10) continue;
          if (frame.length + i - start > maxFrameBytes) {
            finish(const FormatException('Model request frame too large'));
            return;
          }
          frame.add(chunk.sublist(start, i));
          enqueue(frame.takeBytes());
          if (ended) return;
          frame = BytesBuilder(copy: false);
          start = i + 1;
        }
        if (frame.length + chunk.length - start > maxFrameBytes) {
          finish(const FormatException('Model request frame too large'));
          return;
        }
        frame.add(chunk.sublist(start));
      },
      onError: (Object error, StackTrace stack) => finish(error, stack),
      onDone: () => frame.length == 0
          ? finish()
          : finish(const FormatException('Incomplete model request frame')),
      cancelOnError: false,
    );
    return done.future;
  }

  void close() {
    _closed = true;
    _activeSession?.cancel();
  }

  void _check() {
    if (_closed) throw const PluginApiError('CLOSED', '运行环境已关闭。');
    bridge.check();
  }

  Future<String> handle(String frame) async {
    var id = '';
    String fail(String code, String message) => jsonEncode({
      'id': id,
      'ok': false,
      'error': {'code': code, 'message': message},
    });
    try {
      _check();
      if (!bridge.record.manifest.permissions.contains('ai.generate')) {
        return fail('PERMISSION_DENIED', '插件未获准使用模型。');
      }
      if (utf8.encode(frame).length > maxFrameBytes) {
        return fail('LIMIT_EXCEEDED', '模型请求过长。');
      }
      final raw = jsonDecode(frame);
      if (raw is! Map ||
          raw.length != 3 ||
          raw['id'] is! String ||
          !RegExp(r'^[0-9]{1,16}$').hasMatch(raw['id']) ||
          !['model.generate', 'model.list'].contains(raw['method']) ||
          raw['params'] is! Map) {
        return fail('INVALID_ARGUMENT', '模型请求格式不正确。');
      }
      id = raw['id'] as String;
      if (_seen.contains(id)) return fail('DUPLICATE_REQUEST', '请求编号已使用。');
      if (_seen.length >= 4096) return fail('LIMIT_EXCEEDED', '请求次数已达上限。');
      _seen.add(id);
      if (_busy) return fail('BUSY', '已有模型请求正在运行。');
      final params = raw['params'] as Map;
      if (raw['method'] == 'model.list') {
        if (params.isNotEmpty) return fail('INVALID_ARGUMENT', '模型列表参数不正确。');
        if (listModels == null) return fail('METHOD_NOT_FOUND', '宿主暂不支持模型同步。');
        final models = await listModels!();
        _check();
        return jsonEncode({'id': id, 'ok': true, 'result': models});
      }
      if ((params.length != 2 && params.length != 3) ||
          params.keys.any((k) => !['messages', 'tools', 'model'].contains(k)) ||
          (params.containsKey('model') &&
              (params['model'] is! String ||
                  (params['model'] as String).length > 512 ||
                  openSession == null)) ||
          params['messages'] is! List ||
          params['tools'] is! List) {
        return fail('INVALID_ARGUMENT', '模型请求格式不正确。');
      }
      final messages = (params['messages'] as List)
          .map((v) => Map<String, dynamic>.from(v as Map))
          .toList();
      final tools = (params['tools'] as List)
          .map((v) => Map<String, dynamic>.from(v as Map))
          .toList();
      _busy = true;
      try {
        if (!await confirm()) return fail('CANCELLED', '模型请求未获确认。');
        _check();
        final session = openSession == null
            ? newSession()
            : await openSession!(params['model'] as String?);
        try {
          _check();
        } catch (_) {
          session.cancel();
          rethrow;
        }
        _activeSession = session;
        void revoke() {
          try {
            _check();
          } catch (_) {
            session.cancel();
          }
        }

        bridge.registry.addListener(revoke);
        try {
          _check();
          final result = await session.send(messages: messages, tools: tools);
          _check();
          return jsonEncode({'id': id, 'ok': true, 'result': result});
        } finally {
          bridge.registry.removeListener(revoke);
          _activeSession = null;
        }
      } finally {
        _busy = false;
      }
    } on PluginApiError catch (error) {
      return fail(error.code, error.message);
    } on ChatFailure catch (error) {
      try {
        _check();
      } on PluginApiError catch (revoked) {
        return fail(revoked.code, revoked.message);
      }
      return fail(error.code ?? 'OPERATION_FAILED', error.message);
    } catch (_) {
      return fail('OPERATION_FAILED', '模型请求未完成。');
    }
  }
}

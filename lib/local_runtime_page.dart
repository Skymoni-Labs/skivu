// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'chat_api.dart';
import 'local_runtime_sessions.dart';
import 'open_plugin.dart';
import 'open_plugin_bridge.dart';
import 'open_plugin_device.dart';
import 'open_plugin_network.dart';
import 'state.dart';
import 'runtime_install_page.dart';

const _runtimePlatform = MethodChannel('skivu/local_runtime');
bool _runtimePageOpen = false;
bool _runtimeInstallerOpen = false;
int _runtimeRouteSerial = 0;

Future<Object?> localRuntimeCall(
  BuildContext context,
  OpenPluginRecord record,
  OpenPluginRegistry registry,
  String method,
  Map<String, dynamic> params,
) async {
  if (method == 'runtime.providers') {
    return await _runtimePlatform.invokeMethod<Object?>('providers');
  }
  if (method != 'runtime.open' && method != 'runtime.install')
    throw const PluginApiError('METHOD_NOT_FOUND', '运行环境方法不受支持。');
  final component = params['component'], signer = params['signerSha256'];
  if (component is! String ||
      component.length > 300 ||
      !RegExp(
        r'^[A-Za-z][A-Za-z0-9_.]*/[A-Za-z0-9_.$]+$',
      ).hasMatch(component) ||
      signer is! String ||
      !RegExp(r'^[0-9a-f]{64}$').hasMatch(signer) ||
      params.length != 2) {
    throw const PluginApiError('INVALID_ARGUMENT', '请选择来源已核验的本地运行组件。');
  }
  if (_runtimePageOpen || _runtimeInstallerOpen)
    throw const PluginApiError('BUSY', '已有运行环境或组件安装页面打开。');
  if (!context.mounted) throw const PluginApiError('CLOSED', '页面已关闭。');
  if (method == 'runtime.install') {
    _runtimeInstallerOpen = true;
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => RuntimeInstallPage(
            record: record,
            registry: registry,
            component: component,
            signer: signer,
          ),
        ),
      );
      return {'status': 'closed'};
    } finally {
      _runtimeInstallerOpen = false;
    }
  }
  _runtimePageOpen = true;
  try {
    unawaited(
      Navigator.of(context)
          .push<void>(
            MaterialPageRoute(
              builder: (_) => LocalRuntimePage(
                record: record,
                registry: registry,
                component: component,
                signer: signer,
              ),
            ),
          )
          .whenComplete(() => _runtimePageOpen = false),
    );
    return {'status': 'opened'};
  } catch (_) {
    _runtimePageOpen = false;
    rethrow;
  }
}

class LocalRuntimePage extends StatefulWidget {
  const LocalRuntimePage({
    super.key,
    required this.record,
    required this.registry,
    required this.component,
    required this.signer,
  });
  final OpenPluginRecord record;
  final OpenPluginRegistry registry;
  final String component, signer;
  @override
  State<LocalRuntimePage> createState() => _LocalRuntimePageState();
}

class _LocalRuntimePageState extends State<LocalRuntimePage> {
  final coordinator = LocalRuntimeSessions();
  final routeId = ++_runtimeRouteSerial;
  final dialogs = <DialogRoute<bool>>{};
  int? generation;
  bool ready = false, closing = false, confirming = false;
  String? failure;
  Future<void>? stopping;
  bool get active =>
      mounted &&
      !closing &&
      generation != null &&
      coordinator.isActive(generation!);

  @override
  void initState() {
    super.initState();
    widget.registry.addListener(revoked);
    _runtimePlatform.setMethodCallHandler((call) async {
      final args = call.arguments;
      if (args is! Map || args['sessionId'] != routeId) return null;
      if (call.method == 'closed') {
        unawaited(stop());
        if (mounted)
          setState(() {
            ready = false;
            failure = '运行组件已断开，请关闭后重新打开。';
          });
        return null;
      }
      final frame = args['frame'];
      if (frame is! String || generation == null) return null;
      return coordinator.handle(
        generation!,
        call.method == 'model' ? 'model' : 'device',
        frame,
      );
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(start()));
  }

  void revoked() {
    if (widget.registry.records[widget.record.manifest.id] != widget.record ||
        !widget.record.authorized) {
      unawaited(stop());
      if (mounted)
        setState(() {
          ready = false;
          failure = '插件已停用或需要重新授权。';
        });
    }
  }

  Future<bool> confirm(String title, String text) async {
    if (!mounted || closing || confirming) return false;
    confirming = true;
    final navigator = Navigator.of(context, rootNavigator: true);
    final dialog = DialogRoute<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(text)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('允许本次'),
          ),
        ],
      ),
    );
    dialogs.add(dialog);
    try {
      return (await navigator.push(dialog) ?? false) && !closing;
    } finally {
      dialogs.remove(dialog);
      confirming = false;
    }
  }

  Future<void> start() async {
    try {
      final allowed = await confirm(
        '打开本地编程环境？',
        '${widget.record.manifest.name} 将在独立运行组件中执行代码，可修改该组件内的项目、插件和运行环境。请保留重要文件的备份。\n\nSkivu 账号、模型密钥和服务器私有数据不会交给运行组件；模型请求和手机操作仍需宿主授权。关闭此页会停止本次运行。',
      );
      if (!allowed || !mounted || closing) {
        if (mounted && !closing) Navigator.of(context).pop();
        return;
      }
      final bridge = OpenPluginBridge(
        registry: widget.registry,
        record: widget.record,
        host: (method, params) => deviceTasks.dispatch(
          widget.record,
          method,
          params,
          confirm,
          runtimeActive: () => active,
        ),
      );
      generation = await coordinator.open(
        bridge: bridge,
        confirmModel: () async {
          if (!active) return false;
          final identity = jsonEncode(demo.account.connection?.toJson());
          final allowed = await confirm(
            '调用编程模型？',
            '插件：${widget.record.manifest.name}\n模型：${demo.account.connection?.model ?? "尚未选择账号模型"}\n本次会发送编程对话与工具结果，最多生成 4096 token，按当前账号计费。',
          );
          return allowed &&
              active &&
              identity == jsonEncode(demo.account.connection?.toJson());
        },
        newModelSession: () {
          if (!active || !demo.useAccount)
            throw const ChatFailure('请在 Skivu 中登录账号并选择支持工具调用的模型。');
          return demo.account.startAgentChat();
        },
      );
      if (!mounted || closing) {
        await coordinator.close(generation!);
        return;
      }
      await _runtimePlatform.invokeMethod<void>('start', {
        'sessionId': routeId,
        'component': widget.component,
        'signerSha256': widget.signer,
      });
      if (mounted && !closing) setState(() => ready = true);
    } on PlatformException catch (e) {
      if (mounted) setState(() => failure = e.message ?? '本地运行组件启动失败。');
      await stop().catchError((Object _) {});
    } catch (_) {
      if (mounted) setState(() => failure = '本地运行组件启动失败，请核对组件安装及插件授权。');
      await stop().catchError((Object _) {});
    }
  }

  Future<void> stop() => stopping ??= () async {
    closing = true;
    for (final dialog in dialogs.toList()) {
      if (dialog.isActive) dialog.navigator?.removeRoute(dialog, false);
    }
    final closed = generation == null
        ? Future<void>.value()
        : coordinator.close(generation!);
    try {
      await _runtimePlatform.invokeMethod<void>('stop', {'sessionId': routeId});
    } finally {
      await closed;
    }
  }();

  @override
  void dispose() {
    widget.registry.removeListener(revoked);
    unawaited(
      stop().catchError((Object _) {}).whenComplete(() {
        _runtimePlatform.setMethodCallHandler(null);
        return coordinator.dispose();
      }),
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.record.manifest.name)),
    body: failure != null
        ? Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(failure!),
            ),
          )
        : ready
        ? AndroidView(
            viewType: 'skivu/local-runtime',
            creationParams: {'sessionId': routeId},
            creationParamsCodec: const StandardMessageCodec(),
          )
        : const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 18),
                Text('正在准备本地运行环境…'),
              ],
            ),
          ),
  );
}

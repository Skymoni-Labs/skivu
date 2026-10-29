// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
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
import 'local_runtime_models.dart';
import 'model_settings_page.dart';

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
  String preparing = '正在准备本地运行环境…';
  late final LocalRuntimeModels modelAccess;
  Future<void>? stopping;
  bool get active =>
      mounted &&
      !closing &&
      generation != null &&
      coordinator.isActive(generation!);

  @override
  void initState() {
    super.initState();
    modelAccess = LocalRuntimeModels(
      account: demo.account,
      custom: demo.models,
      useAccount: demo.useAccount || demo.models.active == null,
    );
    demo.account.addListener(modelAuthorizationChanged);
    demo.models.addListener(modelAuthorizationChanged);
    widget.registry.addListener(revoked);
    _runtimePlatform.setMethodCallHandler((call) async {
      final args = call.arguments;
      if (args is! Map || args['sessionId'] != routeId) return null;
      if (call.method == 'status') {
        if (mounted && !closing)
          setState(() {
            final files = args['files'];
            preparing = args['phase'] == 'unpacking'
                ? (files is int && files > 0
                      ? '正在解压本地环境，已处理 $files 个文件…'
                      : '正在校验并解压本地环境，首次启动可能需要几分钟…')
                : '正在启动本地编程引擎…';
          });
        return null;
      }
      if (call.method == 'failed') {
        if (mounted)
          setState(() {
            ready = false;
            failure = args['message'] as String? ?? '本地运行引擎已退出。';
          });
        unawaited(stop());
        return null;
      }
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

  void modelAuthorizationChanged() {
    if (!mounted || closing || modelAccess.valid) return;
    setState(() {
      ready = false;
      failure = '账号或模型配置已变化，请重新打开 DSH 以同步授权。';
    });
    unawaited(stop());
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
        '${widget.record.manifest.name} 将在本地执行代码，可修改组件内的项目、插件和运行环境。请保留重要文件的备份。\n\n本次会话可使用同步的账号模型和已保存的自定义模型，后续调用不再逐次弹窗；每次最多生成 4096 token，按所选模型和服务的正常规则计费。账号和模型密钥由 Skivu 保管。手机操作仍需单独授权。关闭此页即结束本次运行和模型授权。',
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
          modelAccess.check();
          return true;
        },
        listModels: modelAccess.list,
        openModelSession: modelAccess.open,
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
    demo.account.removeListener(modelAuthorizationChanged);
    demo.models.removeListener(modelAuthorizationChanged);
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
    appBar: AppBar(
      title: Text(widget.record.manifest.name),
      actions: [
        IconButton(
          tooltip: '运行设置',
          icon: const Icon(Icons.settings_applications),
          onPressed: () async {
            try {
              await _runtimePlatform.invokeMethod<void>('settings', {
                'component': widget.component,
                'signerSha256': widget.signer,
              });
            } on PlatformException catch (e) {
              if (mounted)
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(e.message ?? '组件设置未能打开。')),
                );
            }
          },
        ),
        IconButton(
          tooltip: '自定义模型',
          icon: const Icon(Icons.tune),
          onPressed: () async {
            await Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => Scaffold(
                  appBar: AppBar(title: const Text('模型设置')),
                  body: const SingleChildScrollView(
                    padding: EdgeInsets.all(24),
                    child: ModelSettingsPage(),
                  ),
                ),
              ),
            );
            if (mounted && !modelAccess.valid)
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('模型配置已保存，重新打开 DSH 后同步生效。')),
              );
          },
        ),
      ],
    ),
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
        : Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 18),
                Text(preparing),
              ],
            ),
          ),
  );
}

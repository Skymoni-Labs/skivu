import 'dart:async';
import 'package:flutter/material.dart';
import 'open_plugin.dart';
import 'runtime_install.dart';

class RuntimeInstallPage extends StatefulWidget {
  const RuntimeInstallPage({
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
  State<RuntimeInstallPage> createState() => _RuntimeInstallPageState();
}

class _RuntimeInstallPageState extends State<RuntimeInstallPage>
    with WidgetsBindingObserver {
  late final RuntimeInstall download;
  @override
  void initState() {
    super.initState();
    download = RuntimeInstall(
      component: widget.component,
      signer: widget.signer,
      checkGrant: grant,
    );
    WidgetsBinding.instance.addObserver(this);
    widget.registry.addListener(revoked);
    unawaited(download.check());
  }

  void grant() {
    if (widget.registry.records[widget.record.manifest.id] != widget.record ||
        !widget.record.authorized)
      throw StateError('插件授权已撤销');
  }

  void revoked() {
    try {
      grant();
    } catch (_) {
      download.cancel();
      if (mounted) Navigator.pop(context);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(download.check());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.registry.removeListener(revoked);
    download.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('安装运行组件')),
    body: ListenableBuilder(
      listenable: download,
      builder: (context, _) {
        final r = download.release;
        final busy =
            download.checking || download.downloading || download.installing;
        return ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              widget.record.manifest.name,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 12),
            const Text('在 Skivu 内下载并校验运行组件，随后由安卓系统确认安装。安装后返回这里即可打开。'),
            if (r != null) ...[
              const SizedBox(height: 20),
              Text(
                '版本 ${r.version} · ${(r.size / 1024 / 1024).toStringAsFixed(1)} MB',
              ),
              const SizedBox(height: 8),
              Text(r.notes),
            ],
            if (download.checking) ...[
              const SizedBox(height: 24),
              const LinearProgressIndicator(),
              const Text('正在检查版本和设备兼容性…'),
            ],
            if (download.downloading) ...[
              const SizedBox(height: 24),
              LinearProgressIndicator(
                value: r == null ? null : download.received / r.size,
              ),
              const SizedBox(height: 8),
              Text(
                '已下载 ${(download.received / 1024 / 1024).toStringAsFixed(1)} / ${r == null ? '—' : (r.size / 1024 / 1024).toStringAsFixed(1)} MB',
              ),
              TextButton(onPressed: download.cancel, child: const Text('取消下载')),
            ],
            if (download.message?.isNotEmpty == true) ...[
              const SizedBox(height: 20),
              Text(download.message!),
            ],
            if (download.error != null) ...[
              const SizedBox(height: 20),
              Text(
                download.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 24),
            if (download.ready)
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('完成，返回插件入口'),
              )
            else if (download.path != null)
              FilledButton(
                onPressed: busy ? null : download.install,
                child: Text(download.installing ? '正在核验安装包…' : '安装运行组件'),
              )
            else
              FilledButton(
                onPressed: busy || r == null ? null : download.download,
                child: const Text('下载运行组件'),
              ),
            TextButton(
              onPressed: busy ? null : download.check,
              child: const Text('重新检查'),
            ),
          ],
        );
      },
    ),
  );
}

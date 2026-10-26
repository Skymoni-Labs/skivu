// SPDX-License-Identifier: GPL-3.0-only
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'open_plugin_device.dart';
import 'open_plugin_external.dart';
import 'widgets.dart';

class DeviceSettingsPage extends StatefulWidget {
  const DeviceSettingsPage({super.key, required this.go});
  final ValueChanged<String> go;
  @override
  State<DeviceSettingsPage> createState() => _DeviceSettingsPageState();
}

class _DeviceSettingsPageState extends State<DeviceSettingsPage>
    with WidgetsBindingObserver {
  static const channel = MethodChannel('skivu/device_tasks');
  List<Map> companions = [];
  bool loading = false;
  String? error;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) load();
  }

  Future<void> load() async {
    if (loading) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final list = await channel.invokeListMethod<dynamic>('discover') ?? [];
      if (mounted) setState(() => companions = list.whereType<Map>().toList());
    } on MissingPluginException {
      if (mounted) setState(() => error = '真实手机操控需要在 Android 11 或更新系统中使用。');
    } on PlatformException catch (e) {
      if (mounted) setState(() => error = e.message ?? '设备信息暂不可用，请重试。');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> open(Map companion) async {
    try {
      await channel.invokeMethod('openCompanionSettings', {
        'component': companion['component'],
      });
    } catch (_) {
      if (mounted) setState(() => error = '无法打开设备伴侣，请检查是否仍已安装，刷新后重试。');
    }
  }

  Future<void> download() async {
    try {
      await openPluginExternal(
        {'url': 'https://github.com/skyjjgw/skivu-device-bridge/releases'},
        confirm: (_) async => true,
        check: () {
          if (!mounted) throw StateError('Page closed');
        },
      );
    } catch (_) {
      if (mounted) setState(() => error = '无法打开下载页，请检查网络，或复制下方地址在浏览器打开。');
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: deviceTasks,
    builder: (context, _) {
      final task = deviceTasks.active;
      final current = task == null ? null : deviceTasks.tasks[task.id];
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('手机操控由独立设备伴侣提供。首次启用系统无障碍并信任客户端后，可直接执行已授权插件中的任务；可随时停止或撤销。'),
          const SizedBox(height: 16),
          if (current != null)
            Pane(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('当前任务：${current['summary']}'),
                  TextButton.icon(
                    onPressed: () => deviceTasks.cancel(),
                    icon: const Icon(Icons.stop_circle_outlined),
                    label: const Text('停止当前手机任务'),
                  ),
                ],
              ),
            ),
          if (loading) const LinearProgressIndicator(),
          if (error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(error!),
            ),
          if (!loading && companions.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('未发现已安装的设备伴侣。安装后返回此页刷新；不会创建演示配对。'),
            ),
          for (final companion in companions)
            ListTile(
              title: Text(
                '${companion['label']}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: const Text('在伴侣中查看无障碍状态、客户端信任和撤销设置'),
              trailing: const Icon(Icons.open_in_new),
              onTap: () => open(companion),
            ),
          Wrap(
            spacing: 12,
            children: [
              TextButton.icon(
                onPressed: loading ? null : load,
                icon: const Icon(Icons.refresh),
                label: const Text('刷新设备伴侣'),
              ),
              TextButton.icon(
                onPressed: download,
                icon: const Icon(Icons.download_outlined),
                label: const Text('下载设备伴侣'),
              ),
              TextButton.icon(
                onPressed: () => widget.go('/open-plugins'),
                icon: const Icon(Icons.extension_outlined),
                label: const Text('管理操控插件'),
              ),
            ],
          ),
          const SelectableText(
            'https://github.com/skyjjgw/skivu-device-bridge/releases',
          ),
        ],
      );
    },
  );
}

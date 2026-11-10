// SPDX-License-Identifier: GPL-3.0-only
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'open_plugin_device.dart';
import 'open_plugin_external.dart';
import 'embedded_engine_settings.dart';
import 'product_ui.dart';

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
  bool unsupported = false;
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
      unsupported = false;
      error = null;
    });
    try {
      final list = await channel.invokeListMethod<dynamic>('discover') ?? [];
      if (mounted) setState(() => companions = list.whereType<Map>().toList());
    } on MissingPluginException {
      if (mounted)
        setState(() {
          unsupported = true;
          error = '手机操控需要 Android 11 或更新系统';
        });
    } on PlatformException catch (e) {
      if (mounted)
        setState(() {
          error = e.message ?? '设备信息暂不可用，请重试。';
          unsupported =
              e.code == 'ANDROID_VERSION_UNSUPPORTED' ||
              error!.contains('Android 11');
        });
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
          const MarketHeader(title: '手机操控与设备', subtitle: '让小云协助完成手机上的操作。'),
          const SizedBox(height: 22),
          MarketPanel(
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const EmbeddedEngineSettings(),
              ),
            ),
            child: Row(
              children: [
                MarketGlyph(
                  icon: Icons.phonelink_setup_rounded,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 14),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '设置手机操控',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      SizedBox(height: 6),
                      Text('管理使用范围与所需授权', style: TextStyle(fontSize: 13)),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded),
              ],
            ),
          ),
          const SizedBox(height: 16),
          if (current != null)
            ProductSection(
              title: '正在进行',
              icon: Icons.play_circle_outline,
              children: [
                Text(
                  '${current['summary']}',
                  style: const TextStyle(height: 1.6),
                ),
                TextButton.icon(
                  onPressed: () => deviceTasks.cancel(),
                  icon: const Icon(Icons.stop_circle_outlined),
                  label: const Text('停止当前手机任务'),
                ),
              ],
            ),
          if (error != null)
            ProductError(
              message: unsupported ? error! : '设备信息暂时无法读取',
              detail: error!,
              onRetry: loading ? null : load,
            ),
          MarketPanel(
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text(
                '兼容设备连接',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
              subtitle: const Text('连接已有的设备伴侣', style: TextStyle(fontSize: 12)),
              children: [
                if (loading) const LinearProgressIndicator(minHeight: 2),
                if (!loading && companions.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Text(
                      '还没有连接设备伴侣。使用内置手机操控时，无需另行安装。',
                      style: TextStyle(fontSize: 13, height: 1.6),
                    ),
                  ),
                for (final companion in companions)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('${companion['label']}'),
                    subtitle: const Text('查看连接与信任设置'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => open(companion),
                  ),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    TextButton.icon(
                      onPressed: loading ? null : load,
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: const Text('刷新连接'),
                    ),
                    TextButton.icon(
                      onPressed: download,
                      icon: const Icon(Icons.download_outlined, size: 18),
                      label: const Text('获取设备伴侣'),
                    ),
                    TextButton(
                      onPressed: () => widget.go('/open-plugins'),
                      child: const Text('管理相关插件'),
                    ),
                  ],
                ),
                const ExpansionTile(
                  title: Text('下载来源', style: TextStyle(fontSize: 12)),
                  tilePadding: EdgeInsets.zero,
                  children: [
                    SelectableText(
                      'https://github.com/skyjjgw/skivu-device-bridge/releases',
                      style: TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      );
    },
  );
}

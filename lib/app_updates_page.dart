import 'package:flutter/material.dart';
import 'app_updates.dart';
import 'brand.dart';
import 'widgets.dart';
import 'state.dart' show muted;

class AppUpdatesPage extends StatefulWidget {
  const AppUpdatesPage({super.key});
  @override
  State<AppUpdatesPage> createState() => _AppUpdatesPageState();
}

class _AppUpdatesPageState extends State<AppUpdatesPage>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    appUpdates.check();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) appUpdates.check(silent: true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: appUpdates,
    builder: (context, _) {
      final update = appUpdates;
      final release = update.release;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Pane(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const BrandMark(size: 64),
                const SizedBox(height: 16),
                label('Skivu', size: 26, weight: FontWeight.w600),
                label(
                  update.device == null
                      ? '正在读取版本信息'
                      : '当前 ${update.device!.version} (${update.device!.versionCode})',
                  size: 12,
                  color: muted,
                ),
                const SizedBox(height: 20),
                if (!update.supported)
                  label('请在 Android 客户端中检查和安装更新。', size: 12)
                else if (release == null)
                  FilledButton.icon(
                    onPressed: update.checking ? null : () => update.check(),
                    icon: const Icon(Icons.refresh),
                    label: Text(update.checking ? '正在检查' : '检查新版本'),
                  ),
                if (update.message != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 14),
                    child: Text(
                      update.message!,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                if (update.error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 14),
                    child: Text(
                      update.error!,
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (release != null) ...[
            const SizedBox(height: 16),
            Pane(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  label(
                    '发现新版本 ${release.version}',
                    size: 20,
                    weight: FontWeight.w600,
                  ),
                  const SizedBox(height: 8),
                  label(
                    '${(release.size / 1048576).toStringAsFixed(1)} MB · 构建 ${release.versionCode}',
                    size: 12,
                    color: muted,
                  ),
                  if (release.notes.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Text(
                      release.notes,
                      style: const TextStyle(fontSize: 13, height: 1.6),
                    ),
                  ],
                  const SizedBox(height: 20),
                  if (update.downloading) ...[
                    LinearProgressIndicator(value: update.progress.clamp(0, 1)),
                    const SizedBox(height: 8),
                    label(
                      '下载中 ${(update.progress * 100).toStringAsFixed(0)}%',
                      size: 12,
                    ),
                    TextButton(
                      onPressed: update.cancelDownload,
                      child: const Text('取消下载'),
                    ),
                  ] else if (update.downloadedPath != null)
                    FilledButton.icon(
                      onPressed: update.installing || update.checking
                          ? null
                          : update.install,
                      icon: const Icon(Icons.system_update),
                      label: const Text('安装更新'),
                    )
                  else
                    FilledButton.icon(
                      onPressed: update.checking ? null : update.download,
                      icon: const Icon(Icons.download),
                      label: const Text('下载更新'),
                    ),
                ],
              ),
            ),
          ],
          if (release != null && !update.downloading && !update.installing)
            TextButton.icon(
              onPressed: update.checking ? null : () => update.check(),
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('重新检查版本'),
            ),
          const SizedBox(height: 18),
          label(
            '更新包通过 skymoni.com 转发。下载后校验完整性、应用标识与签名，再由安卓系统确认安装；聊天记录会随覆盖升级保留。',
            size: 11,
            color: muted,
          ),
        ],
      );
    },
  );
}

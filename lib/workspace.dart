import 'package:flutter/material.dart';
import 'open_plugin.dart';
import 'open_plugin_page.dart';
import 'widgets.dart';
import 'state.dart';

class WorkspacePanel extends StatelessWidget {
  const WorkspacePanel({
    super.key,
    required this.close,
    this.registry,
    this.launch,
  });
  final VoidCallback close;
  final OpenPluginRegistry? registry;

  /// Optional launcher for independently hosted runtime integrations.
  final Future<void> Function(BuildContext, OpenPluginRecord)? launch;
  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: Padding(
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              label('工作区', size: 20, weight: FontWeight.w600),
              const Spacer(),
              IconButton(
                tooltip: '关闭工作区',
                onPressed: close,
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Expanded(
            child: ListenableBuilder(
              listenable: registry ?? openPlugins,
              builder: (context, _) {
                final library = registry ?? openPlugins;
                final launchers =
                    library.records.values
                        .where((r) => r.authorized && r.manifest.launcher)
                        .toList()
                      ..sort(
                        (a, b) => a.manifest.name.compareTo(b.manifest.name),
                      );
                return ListView(
                  padding: EdgeInsets.zero,
                  children: [
                    for (final item in [
                      (Icons.folder_outlined, '文件'),
                      (Icons.handyman_outlined, '工具'),
                      (Icons.language, '浏览器'),
                      (Icons.terminal, '终端'),
                    ])
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Pane(
                          padding: const EdgeInsets.all(16),
                          child: Row(
                            children: [
                              Icon(item.$1, color: ink),
                              const SizedBox(width: 14),
                              Expanded(child: label(item.$2)),
                              Text(
                                '即将开放',
                                style: TextStyle(color: ink, fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                      ),
                    if (launchers.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      label('已启用的插件', size: 13, weight: FontWeight.w600),
                      const SizedBox(height: 12),
                      for (final record in launchers)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Pane(
                            padding: EdgeInsets.zero,
                            child: ListTile(
                              leading: Icon(
                                Icons.extension_outlined,
                                color: ink,
                              ),
                              title: Text(
                                record.manifest.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () => launch != null
                                  ? launch!(context, record)
                                  : launchOpenPlugin(
                                      context,
                                      record,
                                      registry: library,
                                    ),
                            ),
                          ),
                        ),
                    ],
                    label('更多能力正在准备中。', size: 12),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    ),
  );
}

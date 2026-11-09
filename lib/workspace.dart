import 'package:flutter/material.dart';
import 'open_plugin.dart';
import 'open_plugin_page.dart';
import 'widgets.dart';
import 'state.dart';
import 'cloud_integration.dart';
import 'cloud_coding_page.dart';
import 'cloud_storage_page.dart';
import 'speech_settings_page.dart';
import 'extensions_page.dart';

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
              listenable: Listenable.merge([
                registry ?? openPlugins,
                cloudIntegration,
              ]),
              builder: (context, _) {
                final library = registry ?? openPlugins;
                final launchers =
                    library.records.values
                        .where(
                          (r) =>
                              r.authorized &&
                              r.manifest.launcher &&
                              !(cloudIntegration.migrated &&
                                  r.manifest.id == 'org.skivu.dsh'),
                        )
                        .toList()
                      ..sort(
                        (a, b) => a.manifest.name.compareTo(b.manifest.name),
                      );
                return ListView(
                  padding: EdgeInsets.zero,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: ListTile(
                        leading: const Icon(Icons.code),
                        title: const Text('小云项目'),
                        subtitle: const Text('内置编程、文件和旧会话'),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const CloudCodingPage(),
                          ),
                        ),
                      ),
                    ),
                    for (final item in <(IconData, String, String, Widget)>[
                      (
                        Icons.folder_outlined,
                        '手机文件',
                        '授权目录、导入与自动保存位置',
                        const CloudStoragePage(),
                      ),
                      (
                        Icons.mic_none,
                        '语音输入与声音',
                        '系统识别、自定义识别和朗读配置',
                        Scaffold(
                          appBar: AppBar(title: const Text('语音输入与声音')),
                          body: const SafeArea(
                            child: SingleChildScrollView(
                              padding: EdgeInsets.all(16),
                              child: SpeechSettingsPage(),
                            ),
                          ),
                        ),
                      ),
                      (
                        Icons.handyman_outlined,
                        '工具与技能',
                        '已安装技能和 MCP 工具',
                        Scaffold(
                          appBar: AppBar(title: const Text('工具与技能')),
                          body: const SafeArea(
                            child: SingleChildScrollView(
                              padding: EdgeInsets.all(16),
                              child: ExtensionsPage(),
                            ),
                          ),
                        ),
                      ),
                    ])
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Pane(
                          padding: EdgeInsets.zero,
                          child: ListTile(
                            leading: Icon(item.$1, color: ink),
                            title: Text(item.$2),
                            subtitle: Text(item.$3),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(builder: (_) => item.$4),
                            ),
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
                    label('执行进度、文件和程序保留在对应的小云对话与项目中。', size: 12),
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

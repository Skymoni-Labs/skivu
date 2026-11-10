import 'package:flutter/material.dart';
import 'dart:async';
import 'cloud_coding_tools.dart';
import 'cloud_integration.dart';
import 'cloud_storage_page.dart';
import 'cloud_project_browser.dart';
import 'cloud_programs_page.dart';

class CloudCodingPage extends StatefulWidget {
  const CloudCodingPage({super.key});
  @override
  State<CloudCodingPage> createState() => _CloudCodingPageState();
}

class _CloudCodingPageState extends State<CloudCodingPage> {
  Map<String, dynamic> status = {};
  List<dynamic> projects = [];
  String? error;
  bool busy = false;
  int serial = 0;
  @override
  void initState() {
    super.initState();
    prepare();
  }

  Future<dynamic> call(
    String tool,
    Map<String, dynamic> args, {
    String? owner,
    String? scope,
  }) async {
    final r = await cloudExecutionChannel
        .invokeMapMethod<String, dynamic>('invoke', {
          'tool': tool,
          'arguments': args,
          'owner': owner ?? 'cloud:project_browser',
          'taskId': scope ?? 'project_browser',
          'requestId':
              'browser_${DateTime.now().microsecondsSinceEpoch}_${++serial}',
        });
    if (r?['outcome'] != 'verified')
      throw StateError(r?['message'] ?? '操作尚未核对。');
    return r?['value'];
  }

  CloudCall scopedCalls({String? owner}) {
    var scope = 'browser_${DateTime.now().microsecondsSinceEpoch}';
    return (tool, args) async {
      final captured = scope;
      try {
        return await call(tool, args, owner: owner, scope: captured);
      } finally {
        if (tool == 'coding.cancel' && scope == captured)
          scope = 'browser_${DateTime.now().microsecondsSinceEpoch}';
      }
    };
  }

  Future<void> refresh() => prepare();

  Future<void> prepare() async {
    setState(() => busy = true);
    final progress = Timer.periodic(const Duration(milliseconds: 500), (
      _,
    ) async {
      try {
        final next = await cloudExecutionChannel
            .invokeMapMethod<String, dynamic>('status');
        if (mounted && busy && next != null) setState(() => status = next);
      } catch (_) {}
    });
    try {
      await call('coding.environment', {});
      projects = List.from(await call('coding.projects.list', {}));
      status =
          await cloudExecutionChannel.invokeMapMethod<String, dynamic>(
            'status',
          ) ??
          {};
      error = null;
    } catch (e) {
      error = '$e';
    } finally {
      progress.cancel();
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('小云项目与运行环境'),
      actions: [
        IconButton(
          onPressed: busy ? null : refresh,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(18),
      children: [
        const Text('直接在小云对话中提出编程需求。运行环境由小云自动准备和管理，无需独立 DSH 插件。'),
        const SizedBox(height: 12),
        const Text('首次准备需要联网下载编程环境；已经安装的环境会继续复用。'),
        if (status['phase'] == 'downloading')
          Text(
            '${((status['downloadedBytes'] as num? ?? 0) / 1048576).toStringAsFixed(1)} / ${((status['downloadBytes'] as num? ?? 0) / 1048576).toStringAsFixed(1)} MB',
          ),
        Text(
          '环境：${const {'not_prepared': '待自动启动', 'verifying': '正在校验资源', 'downloading': '正在下载编程环境', 'extracting': '正在解压资源', 'starting': '正在启动', 'ready': '已就绪', 'interrupted': '需要恢复', 'unavailable': '当前不可用'}[status['phase']] ?? '尚未检查'}${status['installedFiles'] != null && status['phase'] == 'extracting' ? ' · 已处理 ${status['installedFiles']} 个资源文件' : ''}',
        ),
        if (status['migration'] is Map)
          Text(
            '旧数据迁移：${const {'verified': '已备份并核对', 'not_present': '没有旧组件', 'bridge_required': '等待一次性迁移连接', 'not_checked': '尚未核对'}[(status['migration'] as Map)['state']] ?? '等待核对'}',
          ),
        if (error != null) SelectableText(error!),
        if (busy)
          const Padding(
            padding: EdgeInsets.all(16),
            child: LinearProgressIndicator(),
          ),
        FilledButton(
          onPressed: busy ? null : prepare,
          child: const Text('检查并准备内置环境'),
        ),
        const SizedBox(height: 16),
        ListTile(
          title: const Text('全部程序与完整输出'),
          subtitle: const Text('Linux、普通 Android、高权限执行的原始记录与日志。'),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => CloudProgramsPage(
                callForOwner: (owner) => scopedCalls(owner: owner),
              ),
            ),
          ),
        ),
        ListTile(
          title: const Text('执行资源策略'),
          subtitle: const Text('默认跟随设备资源；查看来源或自行调整并发。'),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => const CloudExecutionPolicyPage(),
            ),
          ),
        ),
        ListTile(
          title: const Text('手机文件与自动保存位置'),
          subtitle: const Text('授权目录、导入文件，以及最终成果的保存位置。'),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const CloudStoragePage()),
          ),
        ),
        const Text('已保存项目'),
        for (final project in projects)
          ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: Text(project['name']),
            subtitle: const Text('已保存 · 点击检查文件与进程'),
            onTap: () => browse(project),
          ),
        const Divider(),
        ListTile(
          title: const Text('旧 DSH 会话与历史'),
          subtitle: const Text('读取迁移后的原会话，不重放历史工具或任务。'),
          onTap: busy ? null : legacy,
        ),
        ListTile(
          title: const Text('恢复手机操控浮岛'),
          subtitle: const Text('恢复紧凑模式；不启动或重跑任务。'),
          onTap: () async {
            await cloudExecutionChannel.invokeMethod('overlay.restore');
          },
        ),
        ListTile(
          title: const Text('核对旧 DSH 数据迁移'),
          subtitle: const Text('保留旧组件原数据及私有原始备份。'),
          onTap: busy
              ? null
              : () async {
                  try {
                    var r = await cloudExecutionChannel
                        .invokeMapMethod<String, dynamic>('migration');
                    if (r?['state'] == 'bridge_required')
                      r = await cloudExecutionChannel
                          .invokeMapMethod<String, dynamic>(
                            'migration.activate',
                          );
                    if (r?['state'] == 'verified') {
                      await cloudIntegration.initialize();
                      projects = List.from(
                        await call('coding.projects.list', {}),
                      );
                      status =
                          await cloudExecutionChannel
                              .invokeMapMethod<String, dynamic>('status') ??
                          {};
                      if (mounted) setState(() => status['migration'] = r);
                    }
                    if (mounted)
                      await showDialog<void>(
                        context: context,
                        builder: (c) => AlertDialog(
                          title: const Text('迁移核对'),
                          content: Text(
                            r?['state'] == 'verified'
                                ? '已备份并核对 ${r?['files']} 个文件。旧项目、配置和会话已迁入小云，原组件数据继续保留。${(r?['retainedLinkMetadata'] as num? ?? 0) > 0 ? '\n部分外部链接仅保留原始元数据与备份，请在项目中重新指定对应资源。' : ''}'
                                : r?['message'] ?? '迁移尚未完成，原数据保留。',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(c),
                              child: const Text('关闭'),
                            ),
                          ],
                        ),
                      );
                  } catch (e) {
                    if (mounted) setState(() => error = '$e');
                  }
                },
        ),
      ],
    ),
  );
  Future<void> browse(dynamic p) async {
    try {
      final value = await call('coding.projects.open', {
        'projectId': p['id'],
      }, owner: p['owner']);
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => CloudProjectBrowser(
            project: Map<String, dynamic>.from(p),
            initial: Map<String, dynamic>.from(value),
            call: scopedCalls(owner: p['owner']),
          ),
        ),
      );
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  Future<void> legacy() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            CloudLegacyBrowser(call: (tool, args) => call(tool, args)),
      ),
    );
  }
}

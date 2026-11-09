import 'package:flutter/material.dart';
import 'dart:async';
import 'cloud_coding_tools.dart';
import 'cloud_integration.dart';

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
  }) async {
    final r = await cloudExecutionChannel
        .invokeMapMethod<String, dynamic>('invoke', {
          'tool': tool,
          'arguments': args,
          'owner': owner ?? 'cloud:project_browser',
          'taskId': 'project_browser',
          'requestId':
              'browser_${DateTime.now().microsecondsSinceEpoch}_${++serial}',
        });
    if (r?['outcome'] != 'verified')
      throw StateError(r?['message'] ?? '操作尚未核对。');
    return r?['value'];
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
        Text(
          '环境：${const {'not_prepared': '待自动启动', 'verifying': '正在校验资源', 'extracting': '正在解压资源', 'starting': '正在启动', 'ready': '已就绪', 'interrupted': '需要恢复', 'unavailable': '当前不可用'}[status['phase']] ?? '尚未检查'}${status['installedFiles'] != null && status['phase'] == 'extracting' ? ' · 已处理 ${status['installedFiles']} 个资源文件' : ''}',
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
          builder: (c) => Scaffold(
            appBar: AppBar(title: Text(p['name'])),
            body: ListView(
              children: [
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('在小云对话中指定此项目即可继续编程。恢复后先检查文件和进程，不自动重跑。'),
                ),
                for (final job in value['jobs'])
                  ListTile(
                    title: Text('进程：${job['state']}'),
                    subtitle: Text(job['command'] ?? ''),
                    trailing: job['state'] == 'running'
                        ? TextButton(
                            child: const Text('停止此进程'),
                            onPressed: () async {
                              final result = await call('coding.jobs.stop', {
                                'jobId': job['id'],
                              }, owner: p['owner']);
                              if (c.mounted)
                                ScaffoldMessenger.of(c).showSnackBar(
                                  SnackBar(
                                    content: Text('进程状态：${result['state']}'),
                                  ),
                                );
                            },
                          )
                        : null,
                  ),
                for (final file in value['files'])
                  ListTile(
                    title: Text(file['path']),
                    subtitle: Text(file['type']),
                    onTap: file['type'] != 'file'
                        ? null
                        : () async {
                            try {
                              final data = await call('coding.files.read', {
                                'projectId': p['id'],
                                'path': file['path'],
                              }, owner: p['owner']);
                              if (!c.mounted) return;
                              await Navigator.of(c).push(
                                MaterialPageRoute<void>(
                                  builder: (c) => Scaffold(
                                    appBar: AppBar(title: Text(file['path'])),
                                    body: SingleChildScrollView(
                                      padding: const EdgeInsets.all(16),
                                      child: SelectableText(data['text']),
                                    ),
                                  ),
                                ),
                              );
                            } catch (e) {
                              if (c.mounted)
                                ScaffoldMessenger.of(
                                  c,
                                ).showSnackBar(SnackBar(content: Text('$e')));
                            }
                          },
                  ),
              ],
            ),
          ),
        ),
      );
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  Future<void> legacy() async {
    try {
      final result = await call('coding.legacy.sessions', {});
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (c) => Scaffold(
            appBar: AppBar(title: const Text('旧 DSH 会话')),
            body: ListView(
              children: [
                if ((result['sessions'] as List).isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(18),
                    child: Text('没有可读取的旧会话；迁移状态与原始备份可在上一页核对。'),
                  ),
                for (final session in result['sessions'])
                  ListTile(
                    title: Text(session['path']),
                    subtitle: Text('${session['bytes']} B · 只读历史'),
                    onTap: () async {
                      try {
                        final data = await call('coding.legacy.read', {
                          'sessionId': session['id'],
                        });
                        if (!c.mounted) return;
                        await Navigator.of(c).push(
                          MaterialPageRoute<void>(
                            builder: (c) => Scaffold(
                              appBar: AppBar(title: const Text('历史会话内容')),
                              body: SingleChildScrollView(
                                padding: const EdgeInsets.all(16),
                                child: SelectableText(
                                  '${data['source']}\n\n${data['text']}',
                                ),
                              ),
                            ),
                          ),
                        );
                      } catch (e) {
                        if (c.mounted)
                          ScaffoldMessenger.of(
                            c,
                          ).showSnackBar(SnackBar(content: Text('$e')));
                      }
                    },
                  ),
              ],
            ),
          ),
        ),
      );
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }
}

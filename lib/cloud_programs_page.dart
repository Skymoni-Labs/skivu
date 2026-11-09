import 'package:flutter/material.dart';
import 'cloud_coding_tools.dart';
import 'cloud_project_browser.dart';
import 'cloud_range_reader.dart';
import 'cloud_file_card.dart';
import 'device_engine.dart';

class CloudProgramsPage extends StatefulWidget {
  const CloudProgramsPage({super.key, required this.callForOwner});
  final CloudCall Function(String owner) callForOwner;
  @override
  State<CloudProgramsPage> createState() => _CloudProgramsPageState();
}

class _CloudProgramsPageState extends State<CloudProgramsPage> {
  List<dynamic> rows = [];
  int offset = 0, total = 0;
  int? next;
  final previous = <int>[];
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final page = await cloudExecutionChannel.invokeMapMethod<String, dynamic>(
        'programs.page',
        {'offset': offset},
      );
      if (!mounted) return;
      setState(() {
        rows = page?['items'] ?? [];
        total = page?['total'] ?? 0;
        next = page?['nextOffset'];
        error = null;
      });
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('全部程序与完整输出'),
      actions: [IconButton(onPressed: load, icon: const Icon(Icons.refresh))],
    ),
    body: Column(
      children: [
        if (error != null) SelectableText(error!),
        Text('共 $total 个程序 · 原执行与输出保留，打开记录不会重跑'),
        Expanded(
          child: ListView.builder(
            itemCount: rows.length,
            itemBuilder: (c, i) {
              final job = Map<String, dynamic>.from(rows[i]);
              return ListTile(
                leading: const Icon(Icons.terminal),
                title: Text('${job['backend']} · ${job['state']}'),
                subtitle: Text(
                  '${job['commandPreview'] ?? job['id']}\n${job['owner']}',
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => job['backend'] == 'adb'
                        ? CloudShellLogPage(
                            job: job,
                            call: widget.callForOwner(job['owner']),
                          )
                        : CloudJobLogPage(
                            job: job,
                            call: widget.callForOwner(job['owner']),
                          ),
                  ),
                ),
              );
            },
          ),
        ),
        Wrap(
          children: [
            TextButton(
              onPressed: previous.isEmpty
                  ? null
                  : () {
                      offset = previous.removeLast();
                      load();
                    },
              child: const Text('上一页'),
            ),
            TextButton(
              onPressed: next == null
                  ? null
                  : () {
                      previous.add(offset);
                      offset = next!;
                      load();
                    },
              child: const Text('下一页'),
            ),
          ],
        ),
      ],
    ),
  );
}

class CloudShellLogPage extends StatelessWidget {
  const CloudShellLogPage({super.key, required this.job, required this.call});
  final Map<String, dynamic> job;
  final CloudCall call;
  Future<Map<String, dynamic>> log(
    String tool,
    String stream, {
    int? offset,
  }) async {
    final result = await deviceEngine.invoke(tool, {
      'outputId': job['id'],
      'stream': stream,
      if (offset != null) 'offset': offset,
    }, owner: job['owner']);
    if (!result.verified) throw StateError(result.data['summary']);
    return Map<String, dynamic>.from(result.data['value']);
  }

  Future<void> export(BuildContext context, String stream) async {
    try {
      final content = await log('shell.output.export', stream);
      final project = await call('coding.projects.create', {'name': '高权限原始日志'});
      final path = '$stream.log';
      await call('coding.files.write', {
        'projectId': project['id'],
        'path': path,
        'contentId': content['contentId'],
      });
      final delivery = await call('coding.deliver.prepare', {
        'projectId': project['id'],
        'files': [
          {'path': path, 'purpose': '用户导出的原高权限完整日志快照'},
        ],
      });
      if (context.mounted)
        await showDialog<void>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('完整日志快照'),
            content: SizedBox(
              width: 440,
              child: CloudFileCard(
                ids: (delivery['artifacts'] as List)
                    .map((v) => v['id'] as String)
                    .toList(),
                batches: [delivery['batchId']],
              ),
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
      if (context.mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 2,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('高权限原始输出'),
        actions: [
          PopupMenuButton<String>(
            onSelected: (stream) => export(context, stream),
            itemBuilder: (_) => [
              for (final stream in ['stdout', 'stderr'])
                PopupMenuItem(value: stream, child: Text('保存完整 $stream')),
            ],
          ),
        ],
        bottom: const TabBar(
          tabs: [
            Tab(text: 'stdout'),
            Tab(text: 'stderr'),
          ],
        ),
      ),
      body: TabBarView(
        children: [
          for (final stream in ['stdout', 'stderr'])
            CloudRangeReader(
              title: stream,
              read: (offset) =>
                  log('shell.output.read', stream, offset: offset),
            ),
        ],
      ),
    ),
  );
}

class CloudExecutionPolicyPage extends StatefulWidget {
  const CloudExecutionPolicyPage({super.key});
  @override
  State<CloudExecutionPolicyPage> createState() =>
      _CloudExecutionPolicyPageState();
}

class _CloudExecutionPolicyPageState extends State<CloudExecutionPolicyPage> {
  final fields = {
    for (final key in [
      'maxParallelJobs',
      'maxAndroidJobs',
      'maxBackgroundRuns',
    ])
      key: TextEditingController(),
  };
  Map<String, dynamic>? policy;
  String? error;
  bool saving = false;
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    for (final c in fields.values) c.dispose();
    super.dispose();
  }

  Future<void> load() async {
    try {
      policy = await cloudExecutionChannel.invokeMapMethod<String, dynamic>(
        'resource.policy',
      );
      for (final entry in fields.entries)
        entry.value.text = '${policy?[entry.key] ?? 0}';
    } catch (e) {
      error = '$e';
    }
    if (mounted) setState(() {});
  }

  Future<void> save() async {
    setState(() => saving = true);
    try {
      final values = <String, int>{};
      for (final entry in fields.entries) {
        final value = int.tryParse(entry.value.text);
        if (value == null || value < 0)
          throw const FormatException('请输入非负整数；0表示自动。');
        values[entry.key] = value;
      }
      policy = await cloudExecutionChannel.invokeMapMethod<String, dynamic>(
        'resource.configure',
        values,
      );
      error = null;
    } catch (e) {
      error = '$e';
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('执行资源策略')),
    body: ListView(
      padding: const EdgeInsets.all(18),
      children: [
        const Text(
          '默认跟随实际能力：不添加模型调用次数、程序时长、文件总量或输出保留额度。每个任务可单独设置超时，定时计划可单独设置预算。',
        ),
        const SizedBox(height: 12),
        const Text('并发数填 0：按实际 CPU 和可用内存调度。正数：使用你设置的并发策略；有冲突的写入和手机界面操作仍会排队。'),
        if (policy != null)
          Text(
            '当前 ${policy!['processors']} 核，可用内存 ${((policy!['availableMemoryBytes'] as num) / 1024 / 1024).round()} MiB。Linux / Android 程序自动并发参考值 ${policy!['automaticParallelJobs']}；后台计划 ${policy!['automaticBackgroundRuns'] ?? policy!['automaticParallelJobs']}。',
          ),
        const Text(
          '自动排队按每个程序约 64 MiB、每个后台计划约 160 MiB 的内存参考量结合 CPU 计算。你填写正数可覆盖自动并发值；实际资源不足时会保留队列。',
        ),
        for (final entry in fields.entries)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: TextField(
              controller: entry.value,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: const {
                  'maxParallelJobs': 'Linux 程序并发',
                  'maxAndroidJobs': '普通 Android 程序并发',
                  'maxBackgroundRuns': '后台计划并发',
                }[entry.key],
                helperText: '0 自动；正数由你指定',
              ),
            ),
          ),
        const Text(
          '原始 stdout / stderr 完整保留在应用磁盘，可分页、搜索和导出。Android 后台调度、进程回收、磁盘空间和服务商模型边界仍以实际结果为准。',
        ),
        if (error != null) SelectableText(error!),
        FilledButton(
          onPressed: saving ? null : save,
          child: Text(saving ? '正在保存' : '保存策略'),
        ),
      ],
    ),
  );
}

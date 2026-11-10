import 'package:flutter/material.dart';
import 'product_ui.dart';
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
  bool loading = true;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    if (mounted) setState(() => loading = true);
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
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  void openJob(Map<String, dynamic> job) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => job['backend'] == 'adb'
          ? CloudShellLogPage(job: job, call: widget.callForOwner(job['owner']))
          : CloudJobLogPage(job: job, call: widget.callForOwner(job['owner'])),
    ),
  );

  void jobDetails(Map<String, dynamic> job) => showMarketDetails(
    context,
    name: '运行详情',
    description: '查看这次运行的状态与来源。打开记录不会重新执行。',
    icon: MarketGlyph(
      icon: Icons.history_rounded,
      color: Theme.of(context).colorScheme.primary,
    ),
    details: [
      ('状态', programStateLabel(job['state'])),
      ('类型', programKindLabel(job['backend'])),
      ('执行命令', '${job['commandPreview'] ?? '暂无记录'}'),
      ('运行标识', '${job['id'] ?? '暂无记录'}'),
      ('所属项目', '${job['owner'] ?? '暂无记录'}'),
      ('原始状态', '${job['backend']} / ${job['state']}'),
    ],
    actions: [
      TextButton.icon(
        onPressed: () {
          Navigator.pop(context);
          openJob(job);
        },
        icon: const Icon(Icons.article_outlined, size: 18),
        label: const Text('查看完整输出'),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => ProductScaffold(
    title: '运行记录',
    actions: [
      IconButton(
        onPressed: load,
        tooltip: '刷新运行记录',
        icon: const Icon(Icons.refresh_rounded),
      ),
    ],
    body: Column(
      children: [
        if (error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
            child: ProductError(
              message: '运行记录暂时无法加载',
              detail: error!,
              onRetry: load,
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '$total 条运行记录',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              const Text('查看记录不会重跑', style: TextStyle(fontSize: 12)),
            ],
          ),
        ),
        Expanded(
          child: loading && rows.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : rows.isEmpty && error != null
              ? const SizedBox.shrink()
              : rows.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(18),
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: ProductEmpty(
                      title: '还没有运行记录',
                      description: '小云执行的程序会保留在这里，方便查看进度和结果。',
                      icon: Icons.history_rounded,
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  itemCount: rows.length,
                  itemBuilder: (c, i) {
                    final job = Map<String, dynamic>.from(rows[i]);
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: MarketPanel(
                        onTap: () => openJob(job),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                MarketGlyph(
                                  icon: job['backend'] == 'adb'
                                      ? Icons.phone_android_rounded
                                      : Icons.code_rounded,
                                  color: Theme.of(context).colorScheme.primary,
                                  size: 42,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    '${job['name'] ?? job['title'] ?? '${programKindLabel(job['backend'])} ${offset + i + 1}'}',
                                    style: const TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                IconButton(
                                  tooltip: '运行详情',
                                  onPressed: () => jobDetails(job),
                                  icon: const Icon(Icons.more_horiz_rounded),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                MarketBadge(programStateLabel(job['state'])),
                                const SizedBox(width: 10),
                                const Expanded(
                                  child: Text(
                                    '查看输出与结果',
                                    style: TextStyle(fontSize: 12),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            child: Row(
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
                const Spacer(),
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
          ),
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
  Widget build(BuildContext context) => ProductScaffold(
    title: '并发与资源',
    body: ListView(
      padding: const EdgeInsets.all(18),
      children: [
        ProductSection(
          title: '根据设备安排任务',
          icon: Icons.tune_rounded,
          subtitle: '默认根据手机的处理器和可用内存安排同时运行的任务。',
          children: [
            MarketBadge(
              policy != null &&
                      fields.values.every(
                        (c) => (int.tryParse(c.text) ?? 0) == 0,
                      )
                  ? '自动管理'
                  : policy == null
                  ? '设置待读取'
                  : '已使用自定义并发',
            ),
            const SizedBox(height: 12),
            const Text(
              '这里仅调整并发数量。任务预算、运行时长和输出保存规则保持各自的设置。',
              style: TextStyle(fontSize: 13, height: 1.65),
            ),
          ],
        ),
        if (error != null)
          ProductError(
            message: '资源设置暂时无法读取或保存',
            detail: error!,
            onRetry: saving ? null : load,
          ),
        MarketPanel(
          key: const ValueKey('resource-custom-panel'),
          child: ExpansionTile(
            key: const ValueKey('resource-advanced-settings'),
            tilePadding: EdgeInsets.zero,
            title: const Text(
              '自定义并发',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            subtitle: const Text(
              '需要时再调整，0 表示自动',
              style: TextStyle(fontSize: 12),
            ),
            children: [
              for (final entry in fields.entries)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: TextField(
                    controller: entry.value,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: const {
                        'maxParallelJobs': '编程任务并发',
                        'maxAndroidJobs': '手机程序并发',
                        'maxBackgroundRuns': '后台计划并发',
                      }[entry.key],
                      helperText: '0 自动；填写正数指定数量',
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: saving ? null : save,
                child: Text(saving ? '正在保存…' : '保存并发设置'),
              ),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('设备与调度详情', style: TextStyle(fontSize: 13)),
                children: [
                  if (policy != null)
                    Text(
                      '处理器 ${policy!['processors']} 核 · 可用内存 ${((policy!['availableMemoryBytes'] as num) / 1024 / 1024).round()} MiB。编程/手机程序自动并发参考值 ${policy!['automaticParallelJobs']}；后台计划 ${policy!['automaticBackgroundRuns'] ?? policy!['automaticParallelJobs']}。',
                      style: const TextStyle(fontSize: 12, height: 1.7),
                    ),
                  const Text(
                    '自动调度按每个程序约 64 MiB、每个后台计划约 160 MiB 的内存参考量结合 CPU 计算。填写正数可覆盖自动并发值；资源不足或操作冲突时仍会排队。原始 stdout / stderr 保留在磁盘，可在运行记录中查看与导出。',
                    style: TextStyle(fontSize: 12, height: 1.7),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

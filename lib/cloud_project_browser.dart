import 'package:flutter/material.dart';
import 'product_ui.dart';
import 'cloud_range_reader.dart';
import 'cloud_file_card.dart';

typedef CloudCall =
    Future<dynamic> Function(String tool, Map<String, dynamic> args);

class CloudProjectBrowser extends StatefulWidget {
  const CloudProjectBrowser({
    super.key,
    required this.project,
    required this.initial,
    required this.call,
  });
  final Map<String, dynamic> project, initial;
  final CloudCall call;
  @override
  State<CloudProjectBrowser> createState() => _CloudProjectBrowserState();
}

class _CloudProjectBrowserState extends State<CloudProjectBrowser> {
  late List<dynamic> files, jobs;
  String? cursor, next, error;
  final previous = <String?>[];
  bool busy = false;
  int total = 0;
  @override
  void initState() {
    super.initState();
    files = widget.initial['files'] as List;
    jobs = widget.initial['jobs'] as List;
    next = widget.initial['nextFilesCursor'];
    total = widget.initial['filesTotal'] as int? ?? files.length;
  }

  Future<void> load(String? at) async {
    setState(() => busy = true);
    try {
      final value = await widget.call('coding.files.list', {
        'projectId': widget.project['id'],
        if (at != null) 'cursor': at,
      });
      files = value['items'];
      next = value['nextCursor'];
      total = value['total'];
      cursor = at;
      error = null;
    } catch (e) {
      error = '$e';
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> refresh() async {
    await load(null);
    previous.clear();
    final result = await widget.call('coding.jobs.list', {});
    if (mounted)
      setState(
        () => jobs = (result as List)
            .where((r) => r['projectId'] == widget.project['id'])
            .toList(),
      );
  }

  @override
  Widget build(BuildContext context) => ProductScaffold(
    title: '${widget.project['name']}',
    actions: [
      IconButton(
        tooltip: '刷新文件与进程',
        onPressed: busy ? null : refresh,
        icon: const Icon(Icons.refresh),
      ),
    ],
    body: Column(
      children: [
        if (busy) const LinearProgressIndicator(),
        if (error != null) ProductError(message: '内容暂时无法加载', detail: error!),
        if (jobs.isNotEmpty)
          ExpansionTile(
            title: Text('运行任务 · ${jobs.length}'),
            children: [
              SizedBox(
                height: 180,
                child: ListView.builder(
                  itemCount: jobs.length,
                  itemBuilder: (c, i) {
                    final job = Map<String, dynamic>.from(jobs[i]);
                    return ListTile(
                      title: Text(programStateLabel(job['state'])),
                      subtitle: Text(
                        job['command'] ?? '',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) =>
                              CloudJobLogPage(job: job, call: widget.call),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Text('文件与目录 · $total 项，在小云对话中指定此项目可继续处理。'),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: files.length,
            itemBuilder: (c, i) {
              final file = files[i] as Map;
              return ListTile(
                leading: Icon(
                  file['type'] == 'file'
                      ? Icons.insert_drive_file_outlined
                      : Icons.folder_outlined,
                ),
                title: Text(file['path']),
                subtitle: Text(
                  '${file['type'] == 'file' ? '文件' : '文件夹'}${file['bytes'] != null ? ' · ${file['bytes']} 字节' : ''}',
                ),
                onTap: file['type'] != 'file'
                    ? null
                    : () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => CloudRangeReader(
                            title: file['path'],
                            read: (offset) async => Map<String, dynamic>.from(
                              await widget.call('coding.files.read', {
                                'projectId': widget.project['id'],
                                'path': file['path'],
                                'offset': offset,
                              }),
                            ),
                          ),
                        ),
                      ),
              );
            },
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TextButton(
              onPressed: busy || previous.isEmpty
                  ? null
                  : () async {
                      final at = previous.removeLast();
                      await load(at);
                    },
              child: const Text('上一页'),
            ),
            TextButton(
              onPressed: busy || next == null
                  ? null
                  : () async {
                      previous.add(cursor);
                      await load(next);
                    },
              child: const Text('下一页'),
            ),
          ],
        ),
      ],
    ),
  );
}

class CloudLegacyBrowser extends StatefulWidget {
  const CloudLegacyBrowser({super.key, required this.call});
  final CloudCall call;
  @override
  State<CloudLegacyBrowser> createState() => _CloudLegacyBrowserState();
}

class _CloudLegacyBrowserState extends State<CloudLegacyBrowser> {
  String? cursor;
  final previous = <String?>[];
  late Future<dynamic> page;
  @override
  void initState() {
    super.initState();
    page = load();
  }

  Future<dynamic> load() => widget.call('coding.legacy.sessions', {
    if (cursor != null) 'cursor': cursor,
  });
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('旧 DSH 会话与完整历史')),
    body: FutureBuilder<dynamic>(
      future: page,
      builder: (c, s) {
        if (s.hasError) return SelectableText('${s.error}');
        if (!s.hasData) return const Center(child: CircularProgressIndicator());
        final value = s.data, items = value['items'] as List;
        return Column(
          children: [
            Text('${value['total']} 个只读会话，历史工具不会重放。'),
            Expanded(
              child: ListView.builder(
                itemCount: items.length,
                itemBuilder: (c, i) {
                  final item = items[i];
                  return ListTile(
                    title: Text(item['path']),
                    subtitle: Text('${item['bytes']} B'),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => CloudRangeReader(
                          title: item['path'],
                          read: (offset) async => Map<String, dynamic>.from(
                            await widget.call('coding.legacy.read', {
                              'sessionId': item['id'],
                              'offset': offset,
                            }),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                TextButton(
                  onPressed: previous.isEmpty
                      ? null
                      : () => setState(() {
                          cursor = previous.removeLast();
                          page = load();
                        }),
                  child: const Text('上一页'),
                ),
                TextButton(
                  onPressed: value['nextCursor'] == null
                      ? null
                      : () => setState(() {
                          previous.add(cursor);
                          cursor = value['nextCursor'];
                          page = load();
                        }),
                  child: const Text('下一页'),
                ),
              ],
            ),
          ],
        );
      },
    ),
  );
}

class CloudJobLogPage extends StatefulWidget {
  const CloudJobLogPage({super.key, required this.job, required this.call});
  final Map<String, dynamic> job;
  final CloudCall call;
  @override
  State<CloudJobLogPage> createState() => _CloudJobLogPageState();
}

class _CloudJobLogPageState extends State<CloudJobLogPage> {
  bool busy = false;
  void notice(Object text) {
    if (mounted)
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$text')));
  }

  Future<void> control(String action) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final value = await widget.call('coding.jobs.$action', {
        'jobId': widget.job['id'],
      });
      notice('程序状态：${value['state']}');
    } catch (e) {
      notice(e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> export(String stream) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final path =
          'logs/${widget.job['id']}_${DateTime.now().microsecondsSinceEpoch}.$stream.log';
      final project = await widget.call('coding.projects.create', {
        'name': '程序原始日志快照',
      });
      final exported = await widget.call('coding.jobs.export', {
        'jobId': widget.job['id'],
        'projectId': project['id'],
        'path': path,
        'stream': stream,
      });
      final delivered = await widget.call('coding.deliver.prepare', {
        'projectId': exported['projectId'] ?? widget.job['projectId'],
        'files': [
          {'path': path, 'purpose': '用户明确导出的完整 $stream 原始日志'},
        ],
      });
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('日志快照已保存'),
          content: SizedBox(
            width: 440,
            child: CloudFileCard(
              ids: (delivered['artifacts'] as List)
                  .map((r) => r['id'] as String)
                  .toList(),
              batches: delivered['batchId'] is String
                  ? [delivered['batchId']]
                  : [],
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
      notice(e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 2,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('完整程序输出'),
        actions: [
          PopupMenuButton<String>(
            enabled: !busy,
            onSelected: (a) {
              if (a.startsWith('export:')) {
                export(a.substring(7));
              } else {
                control(a);
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'pause', child: Text('暂停程序')),
              PopupMenuItem(value: 'resume', child: Text('继续原程序')),
              PopupMenuItem(value: 'stop', child: Text('停止此程序')),
              PopupMenuItem(value: 'export:stdout', child: Text('保存完整 stdout')),
              PopupMenuItem(value: 'export:stderr', child: Text('保存完整 stderr')),
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
      body: Column(
        children: [
          if (busy) const LinearProgressIndicator(),
          Expanded(
            child: TabBarView(
              children: [
                for (final stream in ['stdout', 'stderr'])
                  CloudLogStream(
                    job: widget.job,
                    stream: stream,
                    call: widget.call,
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class CloudLogStream extends StatefulWidget {
  const CloudLogStream({
    super.key,
    required this.job,
    required this.stream,
    required this.call,
  });
  final Map<String, dynamic> job;
  final String stream;
  final CloudCall call;
  @override
  State<CloudLogStream> createState() => _CloudLogStreamState();
}

class _CloudLogStreamState extends State<CloudLogStream> {
  int offset = 0;
  final previous = <int>[];
  late Future<Map<String, dynamic>> page;
  final search = TextEditingController();
  List<dynamic>? matches;
  String? query, cursor, error;
  int total = 0;
  @override
  void initState() {
    super.initState();
    page = read();
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  Future<Map<String, dynamic>> read() async {
    final result = await widget.call('coding.jobs.read', {
      'jobId': widget.job['id'],
      '${widget.stream}Offset': offset,
      'length': 48000,
    });
    return {
      ...Map<String, dynamic>.from(result[widget.stream]),
      'state': result['state'],
    };
  }

  Future<void> find({bool next = false}) async {
    try {
      if (!next) {
        query = search.text;
        cursor = null;
      }
      if (query == null || query!.isEmpty) {
        setState(() => matches = null);
        return;
      }
      final result = await widget.call('coding.jobs.search', {
        'jobId': widget.job['id'],
        'query': query,
        if (cursor != null) 'cursor': cursor,
      });
      if (mounted)
        setState(() {
          matches = result['items'];
          total = result['total'];
          cursor = result['nextCursor'];
          error = null;
        });
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.all(8),
        child: TextField(
          controller: search,
          decoration: InputDecoration(
            labelText: '搜索完整 stdout 和 stderr',
            suffixIcon: IconButton(
              onPressed: find,
              icon: const Icon(Icons.search),
            ),
          ),
          onSubmitted: (_) => find(),
        ),
      ),
      if (error != null) ProductError(message: '内容暂时无法加载', detail: error!),
      if (matches != null) ...[
        Text('共 $total 条匹配'),
        Expanded(
          child: ListView.builder(
            itemCount: matches!.length,
            itemBuilder: (c, i) {
              final r = matches![i];
              return ListTile(
                title: Text('${r['stream']} · 第 ${r['line']} 行'),
                subtitle: Text(
                  r['text'] ?? '',
                  maxLines: 5,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => r['textRef'] is String
                        ? CloudRangeReader(
                            title: '完整匹配行',
                            read: (offset) async => Map<String, dynamic>.from(
                              await widget.call('coding.content.read', {
                                'contentId': r['textRef'],
                                'offset': offset,
                              }),
                            ),
                          )
                        : Scaffold(
                            appBar: AppBar(title: const Text('完整匹配行')),
                            body: SingleChildScrollView(
                              padding: const EdgeInsets.all(16),
                              child: SelectableText(r['text'] ?? ''),
                            ),
                          ),
                  ),
                ),
              );
            },
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TextButton(
              onPressed: () => setState(() => matches = null),
              child: const Text('返回原日志'),
            ),
            TextButton(
              onPressed: cursor == null ? null : () => find(next: true),
              child: const Text('更多匹配'),
            ),
          ],
        ),
      ] else
        Expanded(
          child: FutureBuilder<Map<String, dynamic>>(
            future: page,
            builder: (c, s) {
              if (s.hasError) return SelectableText('${s.error}');
              if (!s.hasData)
                return const Center(child: CircularProgressIndicator());
              final value = s.data!;
              return Column(
                children: [
                  Text(
                    '实际状态：${value['state']} · $offset–${value['nextOffset']} / ${value['bytes']} B',
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: SelectableText(value['text'] ?? ''),
                    ),
                  ),
                  Wrap(
                    alignment: WrapAlignment.center,
                    children: [
                      TextButton(
                        onPressed: previous.isEmpty
                            ? null
                            : () => setState(() {
                                offset = previous.removeLast();
                                page = read();
                              }),
                        child: const Text('上一页'),
                      ),
                      TextButton(
                        onPressed: () => setState(() => page = read()),
                        child: const Text('刷新'),
                      ),
                      TextButton(
                        onPressed:
                            value['complete'] == true &&
                                value['state'] != 'running'
                            ? null
                            : () => setState(() {
                                previous.add(offset);
                                offset = (value['nextOffset'] as num).toInt();
                                page = read();
                              }),
                        child: const Text('继续读取'),
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
    ],
  );
}

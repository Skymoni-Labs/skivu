import 'package:flutter/material.dart';
import 'dart:async';
import 'cloud_coding_tools.dart';
import 'cloud_range_reader.dart';

class CloudStoragePage extends StatefulWidget {
  const CloudStoragePage({super.key});
  @override
  State<CloudStoragePage> createState() => _CloudStoragePageState();
}

class _CloudStoragePageState extends State<CloudStoragePage> {
  List<Map<String, dynamic>> grants = [];
  String? error;
  bool busy = false;
  int serial = 0;
  String operationScope = 'storage_${DateTime.now().microsecondsSinceEpoch}';
  Timer? monitor;
  List<Map<String, dynamic>> progress = [];
  @override
  void dispose() {
    monitor?.cancel();
    super.dispose();
  }

  Future<void> cancel() async {
    try {
      await call('coding.cancel', {});
    } finally {
      operationScope = 'storage_${DateTime.now().microsecondsSinceEpoch}';
    }
  }

  @override
  void initState() {
    super.initState();
    refresh();
  }

  Future<dynamic> call(String tool, Map<String, dynamic> args) async {
    final r = await cloudExecutionChannel
        .invokeMapMethod<String, dynamic>('invoke', {
          'tool': tool,
          'arguments': args,
          'owner': 'cloud:project_browser',
          'taskId': operationScope,
          'requestId':
              'storage_${DateTime.now().microsecondsSinceEpoch}_${++serial}',
        });
    if (r?['outcome'] != 'verified')
      throw StateError(r?['message'] ?? '文件操作尚未完成。');
    return r?['value'];
  }

  Future<void> refresh() async {
    try {
      grants =
          (await cloudExecutionChannel.invokeListMethod<dynamic>(
                    'storage.grants',
                  ) ??
                  [])
              .map((v) => Map<String, dynamic>.from(v))
              .toList();
      error = null;
    } catch (e) {
      error = '$e';
    }
    if (mounted) setState(() {});
  }

  Future<void> act(Future<void> Function() operation) async {
    if (busy) return;
    setState(() => busy = true);
    final captured = operationScope;
    monitor = Timer.periodic(const Duration(milliseconds: 500), (_) async {
      try {
        final status = await cloudExecutionChannel
            .invokeMapMethod<String, dynamic>('status');
        final rows = (status?['operations'] as List? ?? [])
            .whereType<Map>()
            .where((r) => r['scope'] == 'cloud:project_browser:$captured')
            .map((r) => Map<String, dynamic>.from(r))
            .toList();
        if (mounted && busy) setState(() => progress = rows);
      } catch (_) {}
    });
    try {
      await operation();
      error = null;
      await refresh();
    } catch (e) {
      error = '$e';
    } finally {
      monitor?.cancel();
      monitor = null;
      if (mounted)
        setState(() {
          busy = false;
          progress = [];
        });
    }
  }

  Future<void> select(bool file) async {
    final granted = await cloudExecutionChannel
        .invokeMapMethod<String, dynamic>(
          file ? 'storage.pick' : 'storage.authorize',
        );
    if (file && granted?['id'] != null) await import(granted!, granted['name']);
  }

  Future<void> import(Map<String, dynamic> grant, String path) async {
    final projects = List<Map<String, dynamic>>.from(
      (await call(
        'coding.projects.list',
        {},
      )).map((v) => Map<String, dynamic>.from(v)),
    );
    if (!mounted) return;
    String? project = projects.firstOrNull?['id'];
    final name = TextEditingController(text: path.split('/').last);
    final accepted = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: const Text('导入到小云项目'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: project,
                items: [
                  const DropdownMenuItem(value: null, child: Text('新建导入项目')),
                  for (final p in projects)
                    DropdownMenuItem(value: p['id'], child: Text(p['name'])),
                ],
                onChanged: (v) => set(() => project = v),
              ),
              TextField(
                controller: name,
                decoration: const InputDecoration(labelText: '项目内保存路径'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('导入'),
            ),
          ],
        ),
      ),
    );
    if (accepted != true) {
      name.dispose();
      return;
    }
    project ??= (await call('coding.projects.create', {'name': '手机导入'}))['id'];
    final target = name.text;
    name.dispose();
    await call('coding.storage.import', {
      'grantId': grant['id'],
      'sourcePath': path,
      'projectId': project,
      'path': target,
    });
    if (mounted)
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已导入项目：$target，可在小云对话中处理。')));
  }

  Future<void> browse(Map<String, dynamic> grant) async {
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CloudGrantedFiles(
          grant: grant,
          call: call,
          onImport: (path) => import(grant, path),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('手机文件与保存位置')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          '最终成果默认保存到 下载/Skivu。选择一个授权目录后，可设为以后的自动保存位置。授权文件可导入项目；原文件保留。',
        ),
        if (error != null) SelectableText(error!),
        if (busy) ...[
          const LinearProgressIndicator(),
          for (final row in progress)
            Text(
              '${row['name']} · ${row['bytes']} / ${row['total'] ?? '未知总量'} 字节',
            ),
          TextButton(onPressed: cancel, child: const Text('取消本次文件操作')),
        ],
        Wrap(
          children: [
            FilledButton(
              onPressed: busy ? null : () => act(() => select(false)),
              child: const Text('添加授权目录'),
            ),
            TextButton(
              onPressed: busy ? null : () => act(() => select(true)),
              child: const Text('导入手机文件'),
            ),
            TextButton(
              onPressed: busy
                  ? null
                  : () => act(() async {
                      await cloudExecutionChannel.invokeMethod(
                        'storage.default',
                        {'grantId': null},
                      );
                    }),
              child: const Text('恢复下载/Skivu'),
            ),
          ],
        ),
        for (final grant in grants)
          ListTile(
            leading: Icon(
              grant['kind'] == 'file'
                  ? Icons.insert_drive_file_outlined
                  : Icons.folder_outlined,
            ),
            title: Text(grant['name']),
            subtitle: Text(
              '${grant['available'] == true ? '已授权' : '授权已失效'}${grant['default'] == true ? ' · 默认保存位置' : ''}',
            ),
            onTap: busy ? null : () => act(() => browse(grant)),
            trailing: PopupMenuButton<String>(
              enabled: !busy,
              onSelected: (choice) => act(() async {
                await cloudExecutionChannel.invokeMethod(
                  choice == 'default' ? 'storage.default' : 'storage.revoke',
                  {'grantId': grant['id']},
                );
              }),
              itemBuilder: (_) => [
                if (grant['available'] == true &&
                    grant['kind'] != 'file' &&
                    grant['write'] == true)
                  const PopupMenuItem(
                    value: 'default',
                    child: Text('设为默认保存位置'),
                  ),
                const PopupMenuItem(value: 'revoke', child: Text('取消授权（保留文件）')),
              ],
            ),
          ),
      ],
    ),
  );
}

class CloudGrantedFiles extends StatefulWidget {
  const CloudGrantedFiles({
    super.key,
    required this.grant,
    required this.call,
    required this.onImport,
    this.path = '',
  });
  final Map<String, dynamic> grant;
  final Future<dynamic> Function(String, Map<String, dynamic>) call;
  final Future<void> Function(String) onImport;
  final String path;
  @override
  State<CloudGrantedFiles> createState() => _CloudGrantedFilesState();
}

class _CloudGrantedFilesState extends State<CloudGrantedFiles> {
  int offset = 0;
  late Future<Map<String, dynamic>> page;
  @override
  void initState() {
    super.initState();
    page = load();
  }

  Future<Map<String, dynamic>> load() async => Map<String, dynamic>.from(
    await widget.call('coding.storage.list', {
      'grantId': widget.grant['id'],
      'path': widget.path,
      'offset': offset,
      'pageSize': 100,
    }),
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.path.isEmpty ? widget.grant['name'] : widget.path),
    ),
    body: FutureBuilder<Map<String, dynamic>>(
      future: page,
      builder: (c, s) {
        if (s.hasError) return SelectableText('${s.error}');
        if (!s.hasData) return const Center(child: CircularProgressIndicator());
        final value = s.data!, items = value['items'] as List;
        return Column(
          children: [
            Expanded(
              child: ListView.builder(
                itemCount: items.length,
                itemBuilder: (c, i) {
                  final item = items[i] as Map;
                  final path = widget.path.isEmpty
                      ? item['name']
                      : '${widget.path}/${item['name']}';
                  final dir = item['mime'] == 'vnd.android.document/directory';
                  return ListTile(
                    title: Text(item['name']),
                    subtitle: Text(dir ? '目录' : '${item['bytes'] ?? '未知'} 字节'),
                    onTap: () async {
                      if (dir) {
                        await Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => CloudGrantedFiles(
                              grant: widget.grant,
                              call: widget.call,
                              onImport: widget.onImport,
                              path: path,
                            ),
                          ),
                        );
                      } else {
                        final mime = item['mime']?.toString() ?? '';
                        if (!mime.startsWith('text/') &&
                            mime != 'application/json') {
                          try {
                            await cloudExecutionChannel.invokeMethod(
                              'storage.open',
                              {'grantId': widget.grant['id'], 'path': path},
                            );
                          } catch (e) {
                            if (context.mounted)
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('系统未能打开文件：$e')),
                              );
                          }
                          return;
                        }
                        String? readId;
                        await Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => CloudRangeReader(
                              title: item['name'],
                              read: (offset) async {
                                final page = Map<String, dynamic>.from(
                                  await widget.call('coding.storage.read', {
                                    'grantId': widget.grant['id'],
                                    'path': path,
                                    'offset': offset,
                                    if (readId != null) 'readId': readId,
                                  }),
                                );
                                readId = page['readId'] as String?;
                                return page;
                              },
                            ),
                          ),
                        );
                      }
                    },
                    trailing: dir
                        ? const Icon(Icons.chevron_right)
                        : TextButton(
                            onPressed: () async {
                              try {
                                await widget.onImport(path);
                              } catch (e) {
                                if (context.mounted)
                                  ScaffoldMessenger.of(
                                    context,
                                  ).showSnackBar(SnackBar(content: Text('$e')));
                              }
                            },
                            child: const Text('导入项目'),
                          ),
                  );
                },
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                TextButton(
                  onPressed: offset == 0
                      ? null
                      : () => setState(() {
                          offset = (offset - 100).clamp(0, offset);
                          page = load();
                        }),
                  child: const Text('上一页'),
                ),
                Text('${value['total']} 项'),
                TextButton(
                  onPressed: value['nextOffset'] == null
                      ? null
                      : () => setState(() {
                          offset = value['nextOffset'];
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

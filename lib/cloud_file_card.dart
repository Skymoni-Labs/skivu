import 'package:flutter/material.dart';
import 'cloud_coding_tools.dart';

class CloudFileCard extends StatefulWidget {
  const CloudFileCard({
    super.key,
    this.ids = const [],
    this.batches = const [],
  });
  final List<String> ids, batches;
  @override
  State<CloudFileCard> createState() => _CloudFileCardState();
}

class _CloudFileCardState extends State<CloudFileCard>
    with WidgetsBindingObserver {
  late Future<Map<String, dynamic>> files;
  final busy = <String>{};
  int offset = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    files = load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didUpdateWidget(CloudFileCard old) {
    super.didUpdateWidget(old);
    if (old.ids.join(',') != widget.ids.join(',') ||
        old.batches.join(',') != widget.batches.join(',')) {
      offset = 0;
      files = load();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted)
      setState(() => files = load());
  }

  Future<Map<String, dynamic>> load() async =>
      await cloudExecutionChannel.invokeMapMethod<String, dynamic>(
        'artifacts.page',
        {
          'ids': widget.ids,
          'batches': widget.batches,
          'offset': offset,
          'pageSize': 20,
        },
      ) ??
      {};
  void notice(String text) {
    if (mounted)
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  String size(dynamic bytes) {
    final n = (bytes as num?)?.toDouble() ?? 0;
    return n >= 1073741824
        ? '${(n / 1073741824).toStringAsFixed(1)} GB'
        : n >= 1048576
        ? '${(n / 1048576).toStringAsFixed(1)} MB'
        : n >= 1024
        ? '${(n / 1024).toStringAsFixed(1)} KB'
        : '${n.toInt()} B';
  }

  Future<void> act(Map<String, dynamic> file, String action) async {
    final id = file['id'] as String;
    if (!busy.add(id)) return;
    setState(() {});
    try {
      if (action == 'preview') {
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => CloudArtifactPreview(id: id, name: file['name']),
          ),
        );
      } else {
        final value = await cloudExecutionChannel
            .invokeMapMethod<String, dynamic>(
              'artifact.${action == 'system' ? 'open' : action}',
              {'id': id, if (action == 'system') 'chooser': true},
            );
        if (action == 'save')
          notice(switch (value?['state']) {
            'cancelled' => '已取消另存，原文件仍保留。',
            'saved' => '已另存并回读核对文件。',
            _ => '已写入所选位置，暂时无法回读核对。',
          });
        files = load();
      }
    } catch (e) {
      notice('$e');
    } finally {
      if (mounted) setState(() => busy.remove(id));
    }
  }

  Widget row(Map<String, dynamic> file) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              file['format'] == 'xlsx'
                  ? Icons.table_chart_outlined
                  : file['format'] == 'zip'
                  ? Icons.folder_zip_outlined
                  : Icons.insert_drive_file_outlined,
              size: 21,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    file['name'],
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    file['state'] != 'delivered'
                        ? '原始文件已缺失或内容变化，未指向其他版本。'
                        : '${(file['format'] ?? 'file').toString().toUpperCase()} · ${size(file['bytes'])} · v${file['version']}${file['sheets'] != null ? ' · ${file['sheets']} 个工作表' : ''}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  Text(
                    switch (file['phoneSaveState']) {
                      'saved' => '已保存：${file['phonePath']}',
                      'changed' => '手机副本已修改：${file['phonePath']}',
                      'missing' => '手机副本已删除；原始成果仍保留。',
                      'pending' => '手机文件正在保存，尚未完成。',
                      'unavailable' => '手机副本暂不可读；原始成果仍保留。',
                      _ => '手机保存未完成，可选择“另存为…”',
                    },
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (file['state'] == 'delivered') ...[
            TextButton(
              onPressed: busy.contains(file['id'])
                  ? null
                  : () => act(file, 'open'),
              child: const Text('打开'),
            ),
            PopupMenuButton<String>(
              enabled: !busy.contains(file['id']),
              tooltip: '成果操作',
              onSelected: (a) => act(file, a),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'preview', child: Text('分页预览原始成果')),
                PopupMenuItem(value: 'system', child: Text('选择打开方式')),
                PopupMenuItem(value: 'save', child: Text('另存为…')),
                PopupMenuItem(value: 'share', child: Text('分享')),
              ],
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Map<String, dynamic>>(
    future: files,
    builder: (context, snapshot) {
      final scheme = Theme.of(context).colorScheme;
      if (snapshot.hasError)
        return Text(
          '成果记录暂时无法读取：${snapshot.error}',
          style: TextStyle(color: scheme.error),
        );
      if (!snapshot.hasData)
        return const Padding(
          padding: EdgeInsets.all(12),
          child: Text('正在核对最终成果…'),
        );
      final page = snapshot.data!;
      final records = (page['items'] as List? ?? [])
          .map((v) => Map<String, dynamic>.from(v))
          .toList();
      return Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: scheme.outlineVariant.withValues(alpha: .6),
          ),
          color: scheme.surfaceContainerLow,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 11, 14, 5),
              child: Text(
                '最终成果 · ${page['total'] ?? records.length} 个文件${offset > 0 ? ' · 从第 ${offset + 1} 项查看' : ''}',
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ),
            if (records.length <= 4)
              for (final file in records) row(file)
            else
              SizedBox(
                height: 360,
                child: ListView.builder(
                  primary: false,
                  itemCount: records.length,
                  itemBuilder: (_, i) => row(records[i]),
                ),
              ),
            if (offset > 0 || page['nextOffset'] != null)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  TextButton(
                    onPressed: offset == 0
                        ? null
                        : () => setState(() {
                            offset = (offset - 20).clamp(0, offset);
                            files = load();
                          }),
                    child: const Text('上一页'),
                  ),
                  TextButton(
                    onPressed: page['nextOffset'] == null
                        ? null
                        : () => setState(() {
                            offset = (page['nextOffset'] as num).toInt();
                            files = load();
                          }),
                    child: const Text('下一页'),
                  ),
                ],
              ),
            const SizedBox(height: 5),
          ],
        ),
      );
    },
  );
}

/// Only the visible page is rendered. The full source remains unchanged and
/// every nextOffset is accessible; system Open retains original formatting.
class CloudArtifactPreview extends StatefulWidget {
  const CloudArtifactPreview({super.key, required this.id, required this.name});
  final String id, name;
  @override
  State<CloudArtifactPreview> createState() => _CloudArtifactPreviewState();
}

class _CloudArtifactPreviewState extends State<CloudArtifactPreview> {
  int offset = 0;
  final previous = <int>[];
  late Future<Map<String, dynamic>> page;
  @override
  void initState() {
    super.initState();
    page = load();
  }

  Future<Map<String, dynamic>> load() async =>
      await cloudExecutionChannel.invokeMapMethod<String, dynamic>(
        'artifact.preview',
        {'id': widget.id, 'offset': offset, 'length': 48000},
      ) ??
      {};
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.name),
      actions: [
        TextButton(
          onPressed: () async {
            try {
              await cloudExecutionChannel.invokeMethod('artifact.open', {
                'id': widget.id,
              });
            } catch (e) {
              if (context.mounted)
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text('$e')));
            }
          },
          child: const Text('系统打开'),
        ),
      ],
    ),
    body: FutureBuilder<Map<String, dynamic>>(
      future: page,
      builder: (context, snapshot) {
        if (snapshot.hasError)
          return Center(child: SelectableText('${snapshot.error}\n可使用上方系统打开。'));
        if (!snapshot.hasData)
          return const Center(child: CircularProgressIndicator());
        final value = snapshot.data!;
        return Column(
          children: [
            if (value['notice'] != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(value['notice']),
              ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: SelectableText(value['text'] ?? ''),
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                TextButton(
                  onPressed: previous.isEmpty
                      ? null
                      : () => setState(() {
                          offset = previous.removeLast();
                          page = load();
                        }),
                  child: const Text('上一页'),
                ),
                Text('字节 $offset–${value['nextOffset']} / ${value['bytes']}'),
                TextButton(
                  onPressed: value['complete'] == true
                      ? null
                      : () => setState(() {
                          previous.add(offset);
                          offset = (value['nextOffset'] as num).toInt();
                          page = load();
                        }),
                  child: const Text('继续读取'),
                ),
              ],
            ),
          ],
        );
      },
    ),
  );
}

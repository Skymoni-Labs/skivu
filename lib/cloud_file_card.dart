import 'package:flutter/material.dart';
import 'cloud_coding_tools.dart';

class _ArtifactPreview extends StatelessWidget {
  const _ArtifactPreview(this.value);
  final Map<String, dynamic> value;
  @override
  Widget build(BuildContext context) {
    if (value['kind'] != 'workbook') return SelectableText(value['text'] ?? '');
    final sheets = value['sheets'] as List;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(value['notice'] ?? ''),
        for (final sheet in sheets) ...[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Text(
              '${sheet['name']} · ${sheet['totalRows']} 行',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Table(
              defaultColumnWidth: const IntrinsicColumnWidth(),
              border: TableBorder.all(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
              children: [
                for (final row in sheet['rows'])
                  TableRow(
                    children: [
                      for (
                        var col = 0;
                        col <
                            (sheet['rows'] as List).fold<int>(
                              0,
                              (n, r) => n > (r as List).length ? n : r.length,
                            );
                        col++
                      )
                        Padding(
                          padding: const EdgeInsets.all(8),
                          child: SelectableText(
                            col < (row as List).length ? '${row[col]}' : '',
                          ),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// IDs are produced by the verified final manifest, never discovered in prose.
class CloudFileCard extends StatefulWidget {
  const CloudFileCard({super.key, required this.ids});
  final List<String> ids;
  @override
  State<CloudFileCard> createState() => _CloudFileCardState();
}

class _CloudFileCardState extends State<CloudFileCard>
    with WidgetsBindingObserver {
  late Future<List<Map<String, dynamic>>> files;
  final busy = <String>{};
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
    if (old.ids.join(',') != widget.ids.join(',')) files = load();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted)
      setState(() => files = load());
  }

  Future<List<Map<String, dynamic>>> load() async {
    final all =
        await cloudExecutionChannel.invokeListMethod<dynamic>('artifacts') ??
        [];
    final records = all
        .whereType<Map>()
        .map((r) => Map<String, dynamic>.from(r))
        .toList();
    return [
      for (final id in widget.ids)
        records.where((r) => r['id'] == id).firstOrNull ??
            {'id': id, 'name': '成果记录不可用', 'state': 'missing'},
    ];
  }

  String size(dynamic bytes) {
    final n = (bytes as num?)?.toDouble() ?? 0;
    return n >= 1048576
        ? '${(n / 1048576).toStringAsFixed(1)} MB'
        : n >= 1024
        ? '${(n / 1024).toStringAsFixed(1)} KB'
        : '${n.toInt()} B';
  }

  void notice(String text) {
    if (mounted)
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> act(Map<String, dynamic> file, String action) async {
    if (action == 'open' &&
        const {
          'xlsx',
          'docx',
          'txt',
          'md',
          'py',
          'js',
          'mjs',
          'dart',
          'kt',
          'java',
          'c',
          'cpp',
          'html',
          'css',
          'csv',
          'yaml',
          'yml',
          'sh',
          'json',
        }.contains(file['format']))
      action = 'preview';
    final id = file['id'] as String;
    if (!busy.add(id)) return;
    setState(() {});
    try {
      if (action == 'preview') {
        final value = await cloudExecutionChannel
            .invokeMapMethod<String, dynamic>('artifact.preview', {'id': id});
        if (!mounted) return;
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (context) => Scaffold(
              appBar: AppBar(title: Text(value?['name'] ?? file['name'])),
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: _ArtifactPreview(value ?? {}),
              ),
            ),
          ),
        );
      } else {
        final value = await cloudExecutionChannel
            .invokeMapMethod<String, dynamic>(
              'artifact.${action == 'system' ? 'open' : action}',
              {'id': id},
            );
        if (action == 'save')
          notice(value?['state'] == 'cancelled' ? '已取消保存，成果仍保留。' : '已保存成果副本。');
      }
    } catch (e) {
      notice('$e');
    } finally {
      if (mounted) setState(() => busy.remove(id));
    }
  }

  @override
  Widget build(
    BuildContext context,
  ) => FutureBuilder<List<Map<String, dynamic>>>(
    future: files,
    builder: (context, snapshot) {
      final scheme = Theme.of(context).colorScheme;
      if (snapshot.hasError)
        return Text(
          '成果记录暂时无法读取，请重新进入对话。',
          style: TextStyle(color: scheme.error),
        );
      if (!snapshot.hasData)
        return const Padding(
          padding: EdgeInsets.all(12),
          child: Text('正在核对最终成果…'),
        );
      final records = snapshot.data!;
      final valid = records.where((r) => r['state'] == 'delivered').length;
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
                '已交付 $valid 个文件${valid < records.length ? ' · ${records.length - valid} 个已失效' : ''}',
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ),
            for (final file in records)
              Padding(
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
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(fontWeight: FontWeight.w600),
                            ),
                            Text(
                              file['state'] != 'delivered'
                                  ? '文件已缺失或内容变化，未指向其他版本。'
                                  : '${(file['format'] ?? 'file').toString().toUpperCase()} · ${size(file['bytes'])} · v${file['version']}${file['sheets'] != null ? ' · ${file['sheets']} 个工作表' : ''}',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: scheme.onSurfaceVariant),
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
                          PopupMenuItem(value: 'preview', child: Text('预览')),
                          PopupMenuItem(
                            value: 'system',
                            child: Text('用其他应用打开'),
                          ),
                          PopupMenuItem(value: 'save', child: Text('保存到…')),
                          PopupMenuItem(value: 'share', child: Text('分享')),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            const SizedBox(height: 5),
          ],
        ),
      );
    },
  );
}

import 'package:flutter/material.dart';

/// Paged rendering only; no truncation of the underlying file or history.
class CloudRangeReader extends StatefulWidget {
  const CloudRangeReader({
    super.key,
    required this.title,
    required this.read,
    this.actions = const [],
  });
  final String title;
  final Future<Map<String, dynamic>> Function(int offset) read;
  final List<Widget> actions;
  @override
  State<CloudRangeReader> createState() => _CloudRangeReaderState();
}

class _CloudRangeReaderState extends State<CloudRangeReader> {
  int offset = 0;
  final previous = <int>[];
  late Future<Map<String, dynamic>> page;
  @override
  void initState() {
    super.initState();
    page = widget.read(offset);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.title),
      actions: [
        ...widget.actions,
        IconButton(
          tooltip: '刷新当前页',
          onPressed: () => setState(() => page = widget.read(offset)),
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: FutureBuilder<Map<String, dynamic>>(
      future: page,
      builder: (context, snapshot) {
        if (snapshot.hasError)
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: SelectableText('${snapshot.error}'),
          );
        if (!snapshot.hasData)
          return const Center(child: CircularProgressIndicator());
        final value = snapshot.data!;
        return Column(
          children: [
            if (value['state'] != null) Text('程序状态：${value['state']}'),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: SelectableText(value['text'] ?? ''),
              ),
            ),
            Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                TextButton(
                  onPressed: previous.isEmpty
                      ? null
                      : () => setState(() {
                          offset = previous.removeLast();
                          page = widget.read(offset);
                        }),
                  child: const Text('上一页'),
                ),
                Text('$offset–${value['nextOffset']} / ${value['bytes']} 字节'),
                TextButton(
                  onPressed:
                      value['complete'] == true && value['state'] != 'running'
                      ? null
                      : () => setState(() {
                          previous.add(offset);
                          offset = (value['nextOffset'] as num).toInt();
                          page = widget.read(offset);
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

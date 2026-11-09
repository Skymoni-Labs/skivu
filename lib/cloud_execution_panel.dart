import 'dart:async';
import 'package:flutter/material.dart';
import 'cloud_coding_tools.dart';
import 'cloud_coding_page.dart';

/// Ephemeral executions are a view of the shared hub, not new saved todos.
class CloudExecutionPanel extends StatefulWidget {
  const CloudExecutionPanel({super.key});
  @override
  State<CloudExecutionPanel> createState() => _CloudExecutionPanelState();
}

class _CloudExecutionPanelState extends State<CloudExecutionPanel>
    with WidgetsBindingObserver {
  List<Map<String, dynamic>> records = [];
  Timer? timer;
  bool reading = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    refresh();
    timer = Timer.periodic(const Duration(seconds: 1), (_) => refresh());
  }

  @override
  void dispose() {
    timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    timer?.cancel();
    if (state == AppLifecycleState.resumed) {
      refresh();
      timer = Timer.periodic(const Duration(seconds: 1), (_) => refresh());
    }
  }

  Future<void> refresh() async {
    if (reading) return;
    reading = true;
    try {
      final values =
          await cloudExecutionChannel.invokeListMethod<dynamic>(
            'execution.list',
          ) ??
          [];
      final next = values
          .whereType<Map>()
          .map((v) => Map<String, dynamic>.from(v))
          .where(
            (r) =>
                r['canStop'] == true ||
                r['canResume'] == true ||
                r['phase'] == 'unknown',
          )
          .toList();
      if (mounted) setState(() => records = next.reversed.take(8).toList());
    } catch (_) {
    } finally {
      reading = false;
    }
  }

  Future<void> control(Map<String, dynamic> record, String action) async {
    try {
      await cloudExecutionChannel.invokeMethod('control', {
        'taskId': record['taskId'],
        'action': action,
      });
      await refresh();
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final r in records)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(r['goal'] ?? '当前小云执行', maxLines: 2),
                Text(
                  '${const {'observing': '正在观察', 'deciding': '正在判断', 'acting': '正在操作', 'waiting': '等待响应', 'waiting_user': '等待你处理', 'paused': '已暂停', 'stopping': '正在停止', 'stopped': '已停止', 'completed': '已完成', 'failed': '失败', 'unknown': '结果待核对'}[r['phase']] ?? '结果已就绪'} · ${r['action'] ?? ''}',
                  maxLines: 3,
                ),
                Wrap(
                  children: [
                    if (r['canPause'] == true)
                      TextButton(
                        onPressed: () => control(r, 'pause'),
                        child: const Text('暂停'),
                      ),
                    if (r['canResume'] == true)
                      TextButton(
                        onPressed: () => control(r, 'resume'),
                        child: const Text('继续'),
                      ),
                    if (r['canStop'] == true)
                      TextButton(
                        onPressed: () => control(r, 'stop'),
                        child: const Text('停止本次执行'),
                      ),
                    if (r['phone'] == true)
                      TextButton(
                        onPressed: () async {
                          await cloudExecutionChannel.invokeMethod(
                            'overlay.restore',
                          );
                        },
                        child: const Text('恢复浮岛'),
                      ),
                    TextButton(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const CloudCodingPage(),
                        ),
                      ),
                      child: const Text('项目与核对'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
    ],
  );
}

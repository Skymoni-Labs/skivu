import 'package:flutter/material.dart';
import 'device_engine.dart';

/// Native records remain independent of chat history and Flutter page lifetime.
class BackgroundAlarmsPage extends StatefulWidget {
  const BackgroundAlarmsPage({super.key});
  @override
  State<BackgroundAlarmsPage> createState() => _BackgroundAlarmsPageState();
}

class _BackgroundAlarmsPageState extends State<BackgroundAlarmsPage>
    with WidgetsBindingObserver {
  List<Map<String, dynamic>> items = [];
  Map<String, dynamic> capability = {};
  bool busy = false;
  String? error;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !busy) refresh();
  }

  Future<void> refresh() async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final state = await deviceEngine.status();
      final values = await deviceEngine.alarms();
      if (mounted)
        setState(() {
          capability = state;
          items = values;
        });
    } catch (_) {
      if (mounted) setState(() => error = '暂时无法读取闹钟，请重试。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> cancel(String id) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await deviceEngine.cancelAlarm(id);
    } catch (_) {
      if (mounted) setState(() => error = '取消结果暂未核实，请刷新核对。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
    if (mounted && error == null) await refresh();
  }

  String due(Map<String, dynamic> item) {
    final at = item['nextAt'];
    if (at is! num) return '';
    final time = DateTime.fromMillisecondsSinceEpoch(at.toInt()).toLocal();
    return '${time.month}月${time.day}日 ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }

  String status(Map<String, dynamic> item) => switch (item['state']) {
    'scheduled' => item['enabled'] == true ? '已设置 · ${due(item)}' : '已停用',
    'cancelled' => '已取消',
    'fired' => switch (item['ringState']) {
      'playing' || 'playing_fallback' => '正在提醒',
      'stopped' => '提醒已停止',
      'timeout' => '提醒已结束',
      'start_failed' ||
      'playback_failed' ||
      'permission_lost' => '响铃未完成，请检查通知和系统授权',
      _ => '已到提醒时间',
    },
    'missed' => '已过期 · 未补响',
    'permission_required' => '等待授权后恢复',
    'prepared' => '调度待核对',
    _ => '需要核对状态',
  };
  Future<void> authorize(String page) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await deviceEngine.openAuthorization(page);
    } catch (_) {
      if (mounted) setState(() => error = '暂时无法打开授权设置，请稍后重试。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget permission(String title, String key, String page) => ListTile(
    title: Text(title),
    subtitle: Text(capability[key] == true ? '已就绪' : '尚未就绪'),
    trailing: const Icon(Icons.chevron_right),
    onTap:
        busy ||
            (page == 'exactAlarms' &&
                (capability['androidSdk'] as int? ?? 31) < 31)
        ? null
        : () => authorize(page),
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('小云闹钟'),
      actions: [
        IconButton(
          onPressed: busy ? null : refresh,
          tooltip: '刷新闹钟',
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('告诉小云时间，就能设置闹钟或倒计时。这里的提醒由小云管理，设置时不会打开系统时钟。'),
        const SizedBox(height: 12),
        if (busy) const LinearProgressIndicator(),
        if (error != null)
          Padding(padding: const EdgeInsets.all(12), child: Text(error!)),
        permission('精确闹钟', 'exactAlarms', 'exactAlarms'),
        permission('提醒通知', 'alarmNotifications', 'notifications'),
        if (capability['alarmReady'] != true)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('完成以上配置后，小云才能登记准确的提醒。已有系统时钟闹钟保持原样。'),
          ),
        const Divider(),
        if (!busy && items.isEmpty)
          const Padding(padding: EdgeInsets.all(20), child: Text('还没有小云闹钟。')),
        for (final item in items)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    (item['label'] as String?)?.isNotEmpty == true
                        ? item['label'] as String
                        : item['kind'] == 'timer'
                        ? '倒计时'
                        : '闹钟',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 6),
                  Text(status(item)),
                  if ((item['days'] as List?)?.isNotEmpty == true)
                    Text(
                      '每周 ${(item['days'] as List).map((d) => ['一', '二', '三', '四', '五', '六', '日'][(d as int) - 1]).join('、')}',
                    ),
                  if (item['error'] != null) const Text('调度状态需要重新核对。'),
                  if (item['enabled'] == true ||
                      {
                        'pending',
                        'starting',
                        'playing',
                        'playing_fallback',
                      }.contains(item['ringState']))
                    TextButton(
                      onPressed: busy
                          ? null
                          : () => cancel(item['id'] as String),
                      child: const Text('取消提醒'),
                    ),
                ],
              ),
            ),
          ),
      ],
    ),
  );
}

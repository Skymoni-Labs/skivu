/// A small display snapshot from a validated call and its native receipt.
/// It never contains arbitrary scripts, screenshots or executable deep links.
Map<String, String> toolResultDetails(
  String tool,
  Map<String, dynamic> args,
  Map<String, dynamic> receipt,
) {
  final value = receipt['value'];
  if (tool.startsWith('tasks.plan.') &&
      receipt['outcome'] == 'verified' &&
      value is Map &&
      value['taskId'] is String &&
      value['goal'] is String) {
    final title = value['goal'] as String;
    return {
      'resultTitle': title.substring(0, title.length.clamp(0, 160)),
      'resultDetail': '小云定时计划 · ${value['state']}',
      'managedTaskId': value['taskId'],
      'managedPlanId': value['id'],
    };
  }
  if (tool.startsWith('tasks.reminder.') &&
      receipt['outcome'] == 'verified' &&
      value is Map &&
      value['managedTaskId'] is String) {
    return {
      'resultTitle': value['desired'] is Map
          ? (value['desired'] as Map)['title'] as String? ?? '系统提醒'
          : '系统提醒',
      'resultDetail': value['state'] == 'cancelled' ? '系统提醒已取消' : '系统日历已核对',
      'managedTaskId': value['managedTaskId'],
      'managedResourceId': value['id'],
    };
  }
  if (const {
        'tasks.create',
        'tasks.update',
        'tasks.complete',
        'tasks.archive',
        'tasks.get',
      }.contains(tool) &&
      receipt['outcome'] == 'verified' &&
      value is Map &&
      value['id'] is String &&
      value['title'] is String) {
    return {
      'resultTitle': value['title'],
      'resultDetail':
          '我的任务 · ${value['archived'] == true
              ? '已归档'
              : value['done'] == true
              ? '已完成'
              : '待办'}${value['date'] == '' ? '' : ' · ${value['date']}'}${value['time'] == '' ? '' : ' ${value['time']}'}',
      'managedTaskId': value['id'],
    };
  }
  final label = args['label'] is String ? (args['label'] as String).trim() : '';
  if (tool == 'clock.alarm.create' &&
      args['hour'] is int &&
      args['minute'] is int) {
    final time =
        '${args['hour'].toString().padLeft(2, '0')}:${args['minute'].toString().padLeft(2, '0')}';
    final days =
        (args['days'] as List? ?? [])
            .whereType<int>()
            .where((d) => d >= 1 && d <= 7)
            .toSet()
            .toList()
          ..sort();
    const names = ['日', '一', '二', '三', '四', '五', '六'];
    return {
      'resultTitle': label.isEmpty ? '$time 闹钟' : label,
      'resultDetail':
          '$time · ${days.isEmpty ? '单次提醒' : '每周${days.map((d) => names[d - 1]).join('、')}'} · 手机时钟',
      'resultTarget': 'clock.alarms',
    };
  }
  if (tool == 'clock.timer.start' && args['seconds'] is int) {
    final seconds = args['seconds'] as int;
    final parts = [
      if (seconds >= 3600) '${seconds ~/ 3600}小时',
      if (seconds % 3600 >= 60) '${seconds % 3600 ~/ 60}分钟',
      if (seconds % 60 != 0) '${seconds % 60}秒',
    ].join();
    return {
      'resultTitle': label.isEmpty ? '$parts倒计时' : label,
      'resultDetail': '$parts · 手机时钟',
      'resultTarget': 'clock.timers',
    };
  }
  if (tool == 'settings.brightness.write' &&
      value is Map &&
      value['level'] is int) {
    return {
      'resultTitle': '屏幕亮度',
      'resultDetail': '亮度 ${(value['level'] as int) * 100 ~/ 255}%',
      'resultTarget': 'settings.display',
    };
  }
  final package = tool == 'apps.launch'
      ? args['package']
      : tool == 'ui.observe' && value is Map
      ? value['package']
      : null;
  if (package is String &&
      RegExp(
        r'^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*)+$',
      ).hasMatch(package) &&
      package.length <= 210) {
    return {'resultTarget': 'app:$package'};
  }
  return {};
}

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'task_database.dart';

final taskPlans = TaskPlans();

class TaskPlan {
  TaskPlan(Map<String, dynamic> value) : data = Map.unmodifiable(value) {
    if (value['id'] is! String ||
        value['taskId'] is! String ||
        value['version'] is! int ||
        value['rule'] is! Map ||
        !{
          'enabled',
          'paused',
          'ended',
          'needs_configuration',
        }.contains(value['state']))
      throw const FormatException('定时计划记录无效。');
  }
  final Map<String, dynamic> data;
  String get id => data['id'];
  String get taskId => data['taskId'];
  int get revision => data['version'];
  String get state => data['state'];
  String get goal => data['goal'];
  Map<String, dynamic> get rule => Map<String, dynamic>.from(data['rule']);
  DateTime? get nextAt => data['nextAt'] is int
      ? DateTime.fromMillisecondsSinceEpoch(data['nextAt'])
      : null;
  Map<String, dynamic>? get lastRun => data['lastRun'] is Map
      ? Map<String, dynamic>.from(data['lastRun'])
      : null;
  String get stateLabel => switch (state) {
    'enabled' => '已启用',
    'paused' => '已暂停',
    'ended' => '已结束',
    _ => '待配置',
  };
  String get ruleLabel => switch (rule['kind']) {
    'daily' => '每天 ${rule['time']}',
    'weekly' =>
      '每周${(rule['weekdays'] as List).map((d) => ['一', '二', '三', '四', '五', '六', '日'][d - 1]).join('、')} ${rule['time']}',
    'interval' => '每 ${rule['intervalMinutes']} 分钟',
    _ => planTime(data['nextAt'] is int ? data['nextAt'] : rule['at']),
  };
}

String planTime(dynamic milliseconds) {
  if (milliseconds is! int) return '无后续执行';
  final d = DateTime.fromMillisecondsSinceEpoch(milliseconds);
  return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

String runStateLabel(String? state) => switch (state) {
  'verified' => '已完成',
  'running' => '处理中',
  'interrupted' => '等待续跑',
  'stopping' => '停止中',
  'unknown' => '待核对',
  'missed' => '已跳过',
  'waiting_conditions' => '等待条件',
  'cancelled' => '已停止',
  _ => '未完成',
};

class TaskPlans extends ChangeNotifier {
  TaskPlans({TaskDatabase? database, bool? supported})
    : database = database ?? TaskDatabase.instance,
      supported = supported ?? TaskDatabase.supported;
  final TaskDatabase database;
  final bool supported;
  List<TaskPlan> records = [];
  List<Map<String, dynamic>> resources = [];
  String? error, pendingTaskId;
  String? pendingAssistantTaskId, pendingAssistantGoal;
  void requestAssistant(String taskId, String goal) {
    pendingAssistantTaskId = taskId;
    pendingAssistantGoal = goal;
    notifyListeners();
  }

  bool loaded = false;
  StreamSubscription<void>? _changes;
  Future<void>? _loading;
  Future<void> initialize() async {
    if (!supported) {
      loaded = true;
      return;
    }
    _changes ??= database.changes.listen((_) => unawaited(refresh()));
    try {
      await database.call('runtime.reconcile');
    } catch (e) {
      error = '$e';
    }
    await refresh();
  }

  Future<void> refresh() =>
      _loading ??= _refresh().whenComplete(() => _loading = null);
  Future<void> _refresh() async {
    if (!supported) {
      loaded = true;
      return;
    }
    try {
      final value = await database.call('plans.list');
      records = (value['plans'] as List)
          .map((p) => TaskPlan(Map<String, dynamic>.from(p)))
          .toList();
      final linked = await database.call('resources.list');
      resources = (linked['resources'] as List)
          .map((p) => Map<String, dynamic>.from(p))
          .toList();
      final route = await database.call('runtime.pendingOpen');
      if (route['taskId'] is String) pendingTaskId = route['taskId'];
      error = null;
    } catch (e) {
      error = e is PlatformException ? e.message : '$e';
    }
    loaded = true;
    notifyListeners();
  }

  List<TaskPlan> forTask(String id) =>
      records.where((p) => p.taskId == id).toList();
  List<Map<String, dynamic>> resourcesFor(String id, String sourceKey) =>
      resources
          .where(
            (r) =>
                r['taskId'] == id ||
                sourceKey.isNotEmpty && r['sourceKey'] == sourceKey,
          )
          .toList();
  Future<Map<String, dynamic>> operate(
    String method,
    Map<String, dynamic> args,
    String requestId,
  ) async {
    if (!supported) throw StateError('此设备暂不支持后台计划。');
    try {
      final result = await database.call(method, {
        'arguments': args,
        'requestId': requestId,
      });
      await refresh();
      return result;
    } on PlatformException catch (e) {
      throw StateError(e.message ?? '安排未能保存。');
    }
  }

  Future<void> authorize(String kind) async {
    await database.call('runtime.authorize', {'kind': kind});
  }

  @override
  void dispose() {
    _changes?.cancel();
    super.dispose();
  }
}

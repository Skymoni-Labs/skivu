import 'package:flutter/material.dart';
import 'task_model_binding.dart';
import 'personal_space.dart';
import 'state.dart' show demo;
import 'task_plans.dart';
import 'cloud_file_card.dart';
import 'cloud_coding_tools.dart';

String _operation() => 'ui:${DateTime.now().microsecondsSinceEpoch}';
String _error(Object e) => e is StateError ? '${e.message}' : '$e';
String resourceLabel(Map r) => switch (r['state']) {
  'verified' => '已核验',
  'cancelled' => '已取消',
  'user_confirmed' => '用户已确认',
  'missing' => '系统对象已不存在',
  'changed_externally' => '系统内容已变化',
  _ => '待核对',
};

Future<void> showTaskPlanEditor(
  BuildContext context,
  PersonalRecord task, {
  TaskPlan? plan,
  TaskPlans? plans,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) =>
      _PlanEditor(task: task, plan: plan, plans: plans ?? taskPlans),
);

class TaskSchedulingPanel extends StatefulWidget {
  const TaskSchedulingPanel({super.key, required this.task, this.plans});
  final PersonalRecord task;
  final TaskPlans? plans;
  @override
  State<TaskSchedulingPanel> createState() => _TaskSchedulingPanelState();
}

class _TaskSchedulingPanelState extends State<TaskSchedulingPanel> {
  TaskPlans get plans => widget.plans ?? taskPlans;
  String? pending, error;
  Future<void> act(String id, Future<void> Function() operation) async {
    if (pending != null) return;
    setState(() => pending = id);
    try {
      await operation();
      if (mounted) setState(() => error = null);
    } catch (e) {
      if (mounted) setState(() => error = _error(e));
    } finally {
      if (mounted) setState(() => pending = null);
    }
  }

  Future<void> planAction(TaskPlan plan, String action) =>
      act(plan.id, () async {
        await plans.operate('plans.$action', {
          'id': plan.id,
          'expectedRevision': plan.revision,
        }, _operation());
      });
  Future<Map<String, dynamic>> fresh(Map r) =>
      plans.database.call('resources.get', {
        'arguments': {'id': r['id']},
      });
  Future<void> cancelResource(Map r) => act(r['id'], () async {
    final current = await fresh(r);
    await plans.operate('resources.cancel', {
      'id': current['id'],
      'expectedRevision': current['version'],
      if (current['actual'] is Map)
        'expectedTag': (current['actual'] as Map)['tag'],
    }, _operation());
    if (r['provider'] == 'clock')
      assistClock('取消这条任务关联的原手机时钟闹钟，并核对结果。找不到原闹钟时不要另建一个。');
  });
  void assistClock(String goal) {
    if (ModalRoute.of(context) is ModalBottomSheetRoute) Navigator.pop(context);
    plans.requestAssistant(widget.task.id, goal);
  }

  Future<void> stopAll() => act('all', () async {
    var needsClock = false;
    for (final p
        in plans.forTask(widget.task.id).where((p) => p.state != 'ended'))
      await plans.operate('plans.cancel', {
        'id': p.id,
        'expectedRevision': p.revision,
      }, _operation());
    for (final r
        in plans
            .resourcesFor(widget.task.id, widget.task.sourceKey)
            .where((r) => r['state'] != 'cancelled')) {
      final current = await fresh(r);
      await plans.operate('resources.cancel', {
        'id': current['id'],
        'expectedRevision': current['version'],
        if (current['actual'] is Map)
          'expectedTag': (current['actual'] as Map)['tag'],
      }, _operation());
      needsClock = needsClock || r['provider'] == 'clock';
    }
    if (needsClock && mounted)
      assistClock('本地后台计划已停止。请继续取消这条任务关联的原系统时钟闹钟并核对；找不到唯一原项时保留待核对，不要新建替代项。');
  });
  @override
  Widget build(BuildContext context) {
    if (!plans.supported) return const SizedBox();
    return AnimatedBuilder(
      animation: plans,
      builder: (context, _) {
        final records = plans.forTask(widget.task.id),
            resources = plans.resourcesFor(
              widget.task.id,
              widget.task.sourceKey,
            );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Divider(height: 28),
            const Text(
              '提醒与定时',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            const Text(
              '截止日期不会自动提醒。系统提醒与小云后台计划分别管理。',
              style: TextStyle(fontSize: 12, height: 1.6),
            ),
            for (final p in records)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '小云后台计划 · ${p.stateLabel}',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      '${p.ruleLabel}\n下次：${planTime(p.data['nextAt'])}',
                      style: const TextStyle(fontSize: 12, height: 1.7),
                    ),
                    if ((p.data['reason'] as String? ?? '').isNotEmpty)
                      Text(
                        p.data['reason'],
                        style: const TextStyle(fontSize: 12),
                      ),
                    if (p.lastRun case final result?) ...[
                      if (const {
                        'running',
                        'interrupted',
                        'waiting_conditions',
                      }.contains(result['state']))
                        Wrap(
                          children: [
                            TextButton(
                              onPressed: pending != null
                                  ? null
                                  : () => act(p.id, () async {
                                      await plans.database.call(
                                        result['paused'] == true
                                            ? 'runs.resume'
                                            : 'runs.pause',
                                        {'id': result['id']},
                                      );
                                      await plans.refresh();
                                    }),
                              child: Text(
                                result['paused'] == true ? '继续本次执行' : '暂停本次执行',
                              ),
                            ),
                            TextButton(
                              onPressed: pending != null
                                  ? null
                                  : () => act(p.id, () async {
                                      await plans.database.call('runs.stop', {
                                        'id': result['id'],
                                      });
                                      await plans.refresh();
                                    }),
                              child: const Text('停止本次执行'),
                            ),
                          ],
                        ),

                      if ((result['artifactIds'] as List? ?? []).isNotEmpty ||
                          (result['artifactBatches'] as List? ?? []).isNotEmpty)
                        CloudFileCard(
                          ids: List<String>.from(result['artifactIds'] ?? []),
                          batches: List<String>.from(
                            result['artifactBatches'] ?? [],
                          ),
                        ),
                      Text(
                        '最近一次：${runStateLabel(result['state'])} · ${planTime(result['dueAt'])}',
                        style: const TextStyle(fontSize: 12, height: 1.7),
                      ),
                      if ((result['result'] as String? ?? '').isNotEmpty)
                        SelectableText(
                          result['result'],
                          style: const TextStyle(fontSize: 13, height: 1.6),
                        )
                      else if ((result['summary'] as String? ?? '').isNotEmpty)
                        Text(
                          result['summary'],
                          style: const TextStyle(fontSize: 12, height: 1.7),
                        ),
                    ],
                    Wrap(
                      spacing: 4,
                      children: [
                        TextButton(
                          onPressed: pending == null
                              ? () => showTaskPlanEditor(
                                  context,
                                  widget.task,
                                  plan: p,
                                  plans: plans,
                                )
                              : null,
                          child: const Text('修改计划'),
                        ),
                        if (p.state != 'ended')
                          TextButton(
                            onPressed: pending == null
                                ? () => planAction(
                                    p,
                                    p.state == 'enabled' ? 'pause' : 'resume',
                                  )
                                : null,
                            child: Text(p.state == 'enabled' ? '暂停' : '启用'),
                          ),
                        if (p.state != 'ended')
                          TextButton(
                            onPressed: pending == null
                                ? () => planAction(p, 'cancel')
                                : null,
                            child: const Text('结束计划'),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            for (final r in resources)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${r['provider'] == 'calendar' ? '系统日历提醒' : '手机时钟关联'} · ${resourceLabel(r)}',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    if (r['actual'] is Map)
                      Text(
                        '${(r['actual'] as Map)['title']} · ${planTime((r['actual'] as Map)['at'])}',
                        style: const TextStyle(fontSize: 12, height: 1.7),
                      ),
                    Text(
                      r['summary'] ?? '',
                      style: const TextStyle(fontSize: 12, height: 1.6),
                    ),
                    Wrap(
                      spacing: 4,
                      children: [
                        TextButton(
                          onPressed: pending == null
                              ? () => act(r['id'], () async {
                                  await plans.operate('resources.verify', {
                                    'id': r['id'],
                                  }, _operation());
                                })
                              : null,
                          child: const Text('重新核对'),
                        ),
                        if (r['provider'] == 'calendar' &&
                            r['state'] != 'cancelled')
                          TextButton(
                            onPressed: pending == null
                                ? () => act(r['id'], () async {
                                    final current = await fresh(r);
                                    if (mounted)
                                      await _showReminder(
                                        context,
                                        widget.task,
                                        plans: plans,
                                        resource: current,
                                      );
                                  })
                                : null,
                            child: const Text('修改提醒'),
                          ),
                        if (r['state'] != 'cancelled')
                          TextButton(
                            onPressed: pending == null
                                ? () => cancelResource(r)
                                : null,
                            child: Text(
                              r['provider'] == 'clock' ? '交给小云取消' : '取消系统提醒',
                            ),
                          ),
                        if (r['provider'] == 'clock' &&
                            r['state'] == 'pending_verification')
                          TextButton(
                            onPressed: pending == null
                                ? () => assistClock(
                                    '请继续处理并核对这条任务关联的原手机时钟安排。先读取之前待处理的修改或取消请求；已生效的动作不要重做，找不到原项不要新建。',
                                  )
                                : null,
                            child: const Text('交给小云继续核对'),
                          ),
                        if (!{'verified', 'cancelled'}.contains(r['state']))
                          TextButton(
                            onPressed: pending == null
                                ? () => act(r['id'], () async {
                                    await plans
                                        .operate('resources.userConfirm', {
                                          'id': r['id'],
                                          'expectedRevision': r['version'],
                                        }, _operation());
                                  })
                                : null,
                            child: const Text('我已核对完成'),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            Wrap(
              spacing: 5,
              children: [
                TextButton.icon(
                  onPressed: pending == null
                      ? () => showTaskPlanEditor(
                          context,
                          widget.task,
                          plans: plans,
                        )
                      : null,
                  icon: const Icon(Icons.schedule, size: 17),
                  label: const Text('添加后台计划'),
                ),
                if (resources.every(
                  (r) => {'cancelled', 'missing'}.contains(r['state']),
                ))
                  TextButton.icon(
                    onPressed: pending == null
                        ? () =>
                              _showReminder(context, widget.task, plans: plans)
                        : null,
                    icon: const Icon(Icons.event_available_outlined, size: 17),
                    label: const Text('添加系统提醒'),
                  ),
              ],
            ),
            if (records.any((p) => p.state != 'ended') ||
                resources.any((r) => r['state'] != 'cancelled'))
              TextButton(
                onPressed: pending == null ? stopAll : null,
                child: const Text('取消此任务的全部安排'),
              ),
            if (error != null)
              Text(
                error!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 12,
                ),
              ),
            if (pending != null) const LinearProgressIndicator(),
          ],
        );
      },
    );
  }
}

class TaskSchedulesPane extends StatelessWidget {
  const TaskSchedulesPane({
    super.key,
    required this.store,
    required this.openTask,
    this.plans,
  });
  final PersonalSpaceStore store;
  final ValueChanged<PersonalRecord> openTask;
  final TaskPlans? plans;
  @override
  Widget build(BuildContext context) {
    final controller = plans ?? taskPlans;
    return AnimatedBuilder(
      animation: Listenable.merge([store, controller]),
      builder: (context, _) {
        final scheduledTasks = {
          ...controller.records.map((p) => p.taskId),
          ...controller.resources.map((r) => r['taskId']),
        };
        final ids = {
          ...scheduledTasks.whereType<String>(),
          for (final t in [...store.tasks, ...store.archivedTasks])
            if (t.sourceKey.isNotEmpty &&
                controller.resources.any((r) => r['sourceKey'] == t.sourceKey))
              t.id,
        };
        final dated = store.tasks
            .where((r) => r.time.isNotEmpty && !ids.contains(r.id))
            .toList();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 12),
            const Text(
              '系统提醒由手机对应软件负责；小云后台处理允许系统延迟。',
              style: TextStyle(fontSize: 12, height: 1.7),
            ),
            if (controller.error != null)
              Text(
                controller.error!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 12,
                ),
              ),
            for (final id in ids)
              if (store.task(id) case final task?)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        TextButton(
                          onPressed: () => openTask(task),
                          child: Text(
                            task.title,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                        TaskSchedulingPanel(task: task, plans: controller),
                      ],
                    ),
                  ),
                ),
            if (ids.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 18),
                child: Text('还没有启用的定时安排。打开一条任务即可添加，或直接交代小云。'),
              ),
            if (dated.isNotEmpty) ...[
              const Padding(
                padding: EdgeInsets.only(top: 20, bottom: 8),
                child: Text(
                  '有时间的待办 · 未自动启用',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              for (final task in dated)
                ListTile(
                  title: Text(task.title),
                  subtitle: Text('${task.date} ${task.time}'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => openTask(task),
                ),
            ],
          ],
        );
      },
    );
  }
}

class _PlanEditor extends StatefulWidget {
  const _PlanEditor({required this.task, required this.plans, this.plan});
  final PersonalRecord task;
  final TaskPlans plans;
  final TaskPlan? plan;
  @override
  State<_PlanEditor> createState() => _PlanEditorState();
}

class _PlanEditorState extends State<_PlanEditor> {
  late final goal = TextEditingController(
    text:
        widget.plan?.goal ??
        (widget.task.body.isEmpty ? widget.task.title : widget.task.body),
  );
  late String kind = widget.plan?.rule['kind'] ?? 'once',
      time =
          widget.plan?.rule['time'] ??
          (widget.task.time.isEmpty ? '09:00' : widget.task.time);
  late DateTime at = widget.plan?.nextAt ?? _defaultAt(widget.task);
  late Set<int> weekdays =
      (widget.plan?.rule['weekdays'] as List? ?? [DateTime.now().weekday])
          .cast<int>()
          .toSet();
  late int interval = widget.plan?.rule['intervalMinutes'] ?? 60,
      calls = widget.plan?.data['maxRequestsPerRun'] ?? 0,
      daily = widget.plan?.data['maxDailyRequests'] ?? 0,
      tokens = widget.plan?.data['maxOutputTokens'] ?? 0;
  late String missed = widget.plan?.data['missedPolicy'] ?? 'latest';
  bool saving = false, useCurrentModel = false;
  late String mode = widget.plan?.data['mode'] ?? 'summary';
  List<Map<String, dynamic>> codingProjects = [];
  Future<void> loadCodingProjects() async {
    try {
      final result = await cloudExecutionChannel
          .invokeMapMethod<String, dynamic>('invoke', {
            'tool': 'coding.projects.list',
            'arguments': <String, dynamic>{},
            'owner': 'cloud:project_selector',
            'taskId': 'project_selector',
            'requestId': 'projects_${DateTime.now().microsecondsSinceEpoch}',
          });
      if (result?['outcome'] != 'verified')
        throw StateError(result?['message'] ?? '无法读取项目。');
      if (mounted)
        setState(
          () => codingProjects = (result!['value'] as List)
              .whereType<Map>()
              .map((v) => Map<String, dynamic>.from(v))
              .where((v) => v['archived'] != true)
              .toList(),
        );
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  late final TextEditingController project = TextEditingController(
    text: widget.plan?.data['projectId'] ?? '',
  );
  late int maxRunSeconds = widget.plan?.data['maxRunSeconds'] ?? 0;
  late int maxDelayMinutes = widget.plan?.data['maxDelayMinutes'] ?? 0;
  late bool allowForeground = widget.plan?.data['allowForeground'] ?? true;
  final invalidNumbers = <String>{};
  String? error;
  @override
  void initState() {
    super.initState();
    if (mode == 'coding') Future.microtask(loadCodingProjects);
  }

  @override
  void dispose() {
    goal.dispose();
    project.dispose();
    super.dispose();
  }

  Future<void> pickDate() async {
    final date = await showDatePicker(
      context: context,
      initialDate: at.isBefore(DateTime.now()) ? DateTime.now() : at,
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime(2100),
    );
    if (date != null && mounted)
      setState(
        () =>
            at = DateTime(date.year, date.month, date.day, at.hour, at.minute),
      );
  }

  Future<void> pickTime() async {
    final current = kind == 'once'
        ? TimeOfDay.fromDateTime(at)
        : TimeOfDay(
            hour: int.parse(time.split(':')[0]),
            minute: int.parse(time.split(':')[1]),
          );
    final value = await showTimePicker(context: context, initialTime: current);
    if (value != null && mounted)
      setState(() {
        time =
            '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
        at = DateTime(at.year, at.month, at.day, value.hour, value.minute);
      });
  }

  Future<void> save() async {
    if (saving) return;
    if (invalidNumbers.isNotEmpty) {
      setState(() => error = '请检查数值参数。');
      return;
    }
    if (demo.activeConnection == null &&
        (widget.plan == null || useCurrentModel)) {
      setState(() => error = '请先在小云中选择模型，再启用后台计划。');
      return;
    }
    setState(() => saving = true);
    try {
      final rule = <String, dynamic>{
        'kind': kind,
        if (widget.plan?.rule['timeZone'] != null)
          'timeZone': widget.plan!.rule['timeZone'],
        if (widget.plan?.rule['followDeviceZone'] != null)
          'followDeviceZone': widget.plan!.rule['followDeviceZone'],
        if (kind == 'once') 'at': at.millisecondsSinceEpoch,
        if (kind == 'daily' || kind == 'weekly') 'time': time,
        if (kind == 'weekly') 'weekdays': weekdays.toList()..sort(),
        if (kind == 'interval') 'intervalMinutes': interval,
      };
      await widget.plans.operate(
        widget.plan == null ? 'plans.create' : 'plans.update',
        {
          if (widget.plan case final p?) ...{
            'id': p.id,
            'expectedRevision': p.revision,
          } else
            'taskId': widget.task.id,
          'goal': goal.text.trim(),
          'mode': mode,
          'projectId': mode == 'coding' ? project.text.trim() : '',
          'rule': rule,
          'maxRequestsPerRun': calls,
          'maxDailyRequests': daily,
          'maxOutputTokens': tokens,
          'missedPolicy': missed,
          'maxDelayMinutes': maxDelayMinutes,
          'maxRunSeconds': maxRunSeconds,
          'allowForeground': allowForeground,
          if (widget.plan == null || useCurrentModel) ...{
            'modelIdentity': scheduledModelIdentity(demo),
            'modelBinding': scheduledModelBinding(demo),
            'modelName': demo.model,
          },
        },
        _operation(),
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted)
        setState(() {
          saving = false;
          error = _error(e);
        });
    }
  }

  Widget number(
    String label,
    int value,
    ValueChanged<int> change, {
    int minimum = 0,
    String? note,
  }) => TextFormField(
    key: ValueKey('plan-number-$label'),
    initialValue: '$value',
    enabled: !saving,
    keyboardType: TextInputType.number,
    decoration: InputDecoration(labelText: label, helperText: note),
    autovalidateMode: AutovalidateMode.onUserInteraction,
    validator: (text) {
      final n = int.tryParse(text ?? '');
      return n == null || n < minimum
          ? '请输入${minimum == 0 ? '非负' : '正'}整数'
          : null;
    },
    onChanged: (text) {
      final n = int.tryParse(text);
      if (n == null || n < minimum) {
        invalidNumbers.add(label);
      } else {
        invalidNumbers.remove(label);
        change(n);
      }
    },
  );
  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(
      20,
      12,
      20,
      MediaQuery.viewInsetsOf(context).bottom + 20,
    ),
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .87,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '小云后台计划',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            const Text(
              '到时间由小云处理，允许系统延迟。已授权步骤使用与前台相同的能力；界面操作条件不足时等待。',
              style: TextStyle(fontSize: 12, height: 1.7),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: goal,
              enabled: !saving,
              minLines: 2,
              maxLines: 5,
              decoration: const InputDecoration(
                labelText: '交给小云做什么',
                counterText: '',
              ),
            ),
            DropdownButtonFormField<String>(
              initialValue: kind,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '执行规则'),
              items: [
                for (final e in const {
                  'once': '一次',
                  'daily': '每天',
                  'weekly': '每周',
                  'interval': '固定间隔',
                }.entries)
                  DropdownMenuItem(value: e.key, child: Text(e.value)),
              ],
              onChanged: saving ? null : (v) => setState(() => kind = v!),
            ),
            DropdownButtonFormField<String>(
              initialValue: mode,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '任务方式'),
              items: const [
                DropdownMenuItem(value: 'summary', child: Text('整理／生成内容')),
                DropdownMenuItem(
                  value: 'local_tasks',
                  child: Text('管理待办（需要实际修改回执）'),
                ),
                DropdownMenuItem(
                  value: 'device_action',
                  child: Text('操作手机能力（需要实际核验）'),
                ),
                DropdownMenuItem(value: 'coding', child: Text('内置项目编程与最终交付')),
              ],
              onChanged: saving
                  ? null
                  : (v) {
                      setState(() => mode = v!);
                      if (v == 'coding') loadCodingProjects();
                    },
            ),
            if (mode == 'coding')
              DropdownButtonFormField<String>(
                key: ValueKey(codingProjects.map((p) => p['id']).join(',')),
                initialValue:
                    project.text.isEmpty ||
                        codingProjects.any((p) => p['id'] == project.text)
                    ? project.text
                    : null,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: '执行项目',
                  helperText: '可按目标选择或创建项目，也可主动限定到一个现有项目。',
                ),
                items: [
                  const DropdownMenuItem<String>(
                    value: '',
                    child: Text('按目标选择或创建项目'),
                  ),
                  for (final p in codingProjects)
                    DropdownMenuItem<String>(
                      value: p['id'],
                      child: Text(p['name']),
                    ),
                ],
                onChanged: saving
                    ? null
                    : (id) => setState(() => project.text = id ?? ''),
              ),
            Wrap(
              spacing: 8,
              children: [
                if (kind == 'once')
                  TextButton(
                    onPressed: saving ? null : pickDate,
                    child: Text('${at.year}-${at.month}-${at.day}'),
                  ),
                if (kind != 'interval')
                  TextButton(
                    onPressed: saving ? null : pickTime,
                    child: Text(
                      kind == 'once'
                          ? '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}'
                          : time,
                    ),
                  ),
              ],
            ),
            if (kind == 'weekly')
              Wrap(
                spacing: 5,
                children: [
                  for (var d = 1; d <= 7; d++)
                    FilterChip(
                      label: Text(
                        '周${['一', '二', '三', '四', '五', '六', '日'][d - 1]}',
                      ),
                      selected: weekdays.contains(d),
                      onSelected: saving
                          ? null
                          : (v) => setState(() {
                              if (v)
                                weekdays.add(d);
                              else
                                weekdays.remove(d);
                            }),
                    ),
                ],
              ),
            if (kind == 'interval')
              number(
                '间隔（分钟）',
                interval,
                (v) => interval = v,
                minimum: 1,
                note: '短间隔使用单次调度续排；实际触发仍受Android/OEM条件影响，不保证准点。',
              ),
            Text(
              '使用模型：${widget.plan?.data['modelName'] ?? demo.model}',
              style: const TextStyle(fontSize: 12, height: 2),
            ),
            if (widget.plan != null)
              CheckboxListTile(
                value: useCurrentModel,
                onChanged: saving
                    ? null
                    : (v) => setState(() => useCurrentModel = v ?? false),
                title: const Text('改用当前选中的模型'),
                contentPadding: EdgeInsets.zero,
              ),
            const Text('默认无限制／跟随实际能力。下面仅在你主动填写正数时生效。'),
            number('本次模型请求预算（0不限制）', calls, (v) => calls = v),
            number('每日模型请求预算（0不限制）', daily, (v) => daily = v),
            number('输出 tokens（0沿用模型配置）', tokens, (v) => tokens = v),
            number(
              '累计运行时长上限（秒，0不限制）',
              maxRunSeconds,
              (v) => maxRunSeconds = v,
              note: '正数由执行心跳核对；不改变其他任务或程序的配置。',
            ),
            number(
              '允许迟到分钟数（0不限制）',
              maxDelayMinutes,
              (v) => maxDelayMinutes = v,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('允许已授权的前台步骤'),
              subtitle: const Text('锁屏或系统不允许时等待；不会为展示状态打开小云。'),
              value: allowForeground,
              onChanged: saving
                  ? null
                  : (v) => setState(() => allowForeground = v),
            ),
            DropdownButtonFormField<String>(
              initialValue: missed,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '错过时间时'),
              items: const [
                DropdownMenuItem(
                  value: 'latest',
                  child: Text('处理最近一次，按上方允许迟到时间判断'),
                ),
                DropdownMenuItem(value: 'skip', child: Text('跳过迟到超过一分钟的执行')),
              ],
              onChanged: saving ? null : (v) => setState(() => missed = v!),
            ),
            const SizedBox(height: 8),
            const Text(
              '没有额外全局调用额度。暂停／结束计划只影响后续触发；“停止本次执行”单独控制当前任务。',
              style: TextStyle(fontSize: 12, height: 1.7),
            ),
            if (error != null)
              Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            const SizedBox(height: 14),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: saving ? null : save,
                child: Text(
                  saving
                      ? '正在保存…'
                      : widget.plan == null
                      ? '启用计划'
                      : '保存修改',
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

DateTime _defaultAt(PersonalRecord task) {
  final existing = DateTime.tryParse(
    '${task.date}T${task.time.isEmpty ? '09:00' : task.time}:00',
  );
  if (existing != null && existing.isAfter(DateTime.now())) return existing;
  final tomorrow = DateTime.now().add(const Duration(days: 1));
  return DateTime(tomorrow.year, tomorrow.month, tomorrow.day, 9);
}

Future<void> _showReminder(
  BuildContext context,
  PersonalRecord task, {
  required TaskPlans plans,
  Map<String, dynamic>? resource,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) => _ReminderEditor(task: task, plans: plans, resource: resource),
);

class _ReminderEditor extends StatefulWidget {
  const _ReminderEditor({
    required this.task,
    required this.plans,
    this.resource,
  });
  final PersonalRecord task;
  final TaskPlans plans;
  final Map<String, dynamic>? resource;
  @override
  State<_ReminderEditor> createState() => _ReminderEditorState();
}

class _ReminderEditorState extends State<_ReminderEditor> {
  late DateTime at = widget.resource?['actual'] is Map
      ? DateTime.fromMillisecondsSinceEpoch(
          (widget.resource!['actual'] as Map)['at'],
        )
      : _defaultAt(widget.task);
  late final title = TextEditingController(
    text: widget.resource?['actual'] is Map
        ? (widget.resource!['actual'] as Map)['title']
        : widget.task.title,
  );
  String? error;
  bool saving = false;
  String repeat = 'keep';
  Set<int> weekdays = {DateTime.now().weekday};
  @override
  void dispose() {
    title.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (saving) return;
    setState(() => saving = true);
    try {
      final r = widget.resource;
      await widget.plans.operate(
        r == null ? 'resources.create' : 'resources.update',
        {
          if (r == null)
            'taskId': widget.task.id
          else ...{
            'id': r['id'],
            'expectedRevision': r['version'],
            'expectedTag': (r['actual'] as Map)['tag'],
          },
          'title': title.text.trim(),
          'at': at.millisecondsSinceEpoch,
          if (repeat != 'keep') 'repeat': repeat,
          if (repeat == 'weekly') 'weekdays': weekdays.toList()..sort(),
          if (r == null) 'reminderMinutes': 0,
        },
        _operation(),
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted)
        setState(() {
          saving = false;
          error = _error(e);
        });
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(
      20,
      16,
      20,
      MediaQuery.viewInsetsOf(context).bottom + 20,
    ),
    child: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '系统日历提醒',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          const Text(
            '写入手机可写日历，由系统日历负责提醒。仅修改本地待办不会修改这里的提醒。',
            style: TextStyle(fontSize: 12, height: 1.7),
          ),
          TextField(
            controller: title,
            maxLength: 160,
            enabled: !saving,
            decoration: const InputDecoration(labelText: '提醒名称'),
          ),
          Wrap(
            spacing: 8,
            children: [
              TextButton(
                onPressed: saving
                    ? null
                    : () async {
                        final date = await showDatePicker(
                          context: context,
                          initialDate: at.isBefore(DateTime.now())
                              ? DateTime.now()
                              : at,
                          firstDate: DateTime.now().subtract(
                            const Duration(days: 1),
                          ),
                          lastDate: DateTime(2100),
                        );
                        if (date != null && mounted)
                          setState(
                            () => at = DateTime(
                              date.year,
                              date.month,
                              date.day,
                              at.hour,
                              at.minute,
                            ),
                          );
                      },
                child: Text('${at.year}-${at.month}-${at.day}'),
              ),
              TextButton(
                onPressed: saving
                    ? null
                    : () async {
                        final time = await showTimePicker(
                          context: context,
                          initialTime: TimeOfDay.fromDateTime(at),
                        );
                        if (time != null && mounted)
                          setState(
                            () => at = DateTime(
                              at.year,
                              at.month,
                              at.day,
                              time.hour,
                              time.minute,
                            ),
                          );
                      },
                child: Text(
                  '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}',
                ),
              ),
            ],
          ),
          DropdownButtonFormField<String>(
            initialValue: repeat,
            isExpanded: true,
            decoration: const InputDecoration(labelText: '重复'),
            items: const [
              DropdownMenuItem(value: 'keep', child: Text('保留原重复规则（新提醒为一次）')),
              DropdownMenuItem(value: 'none', child: Text('一次')),
              DropdownMenuItem(value: 'daily', child: Text('每天')),
              DropdownMenuItem(value: 'weekly', child: Text('每周')),
            ],
            onChanged: saving ? null : (v) => setState(() => repeat = v!),
          ),
          if (repeat == 'weekly')
            Wrap(
              spacing: 3,
              children: [
                for (var d = 1; d <= 7; d++)
                  FilterChip(
                    label: Text(
                      '周${['一', '二', '三', '四', '五', '六', '日'][d - 1]}',
                    ),
                    selected: weekdays.contains(d),
                    onSelected: saving
                        ? null
                        : (v) => setState(() {
                            if (v)
                              weekdays.add(d);
                            else
                              weekdays.remove(d);
                          }),
                  ),
              ],
            ),
          TextButton(
            onPressed: () => widget.plans.authorize('calendar'),
            child: const Text('允许访问系统日历'),
          ),
          if (error != null)
            Text(
              error!,
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontSize: 12,
              ),
            ),
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              onPressed: saving ? null : save,
              child: Text(saving ? '正在保存…' : '登记并核对系统提醒'),
            ),
          ),
        ],
      ),
    ),
  );
}

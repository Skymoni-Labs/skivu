import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'cloud_execution_disclosure.dart';
import 'state.dart';
import 'device_tool_catalog.dart';
import 'personal_space.dart';
import 'task_plans.dart';

/// A view of actual receipts. Rendering or restoring a card executes nothing.
class TaskResult {
  const TaskResult({
    required this.title,
    required this.detail,
    required this.status,
    required this.tool,
    this.target,
    this.managedTaskId,
    this.managedPlanId,
    this.managedResourceId,
    this.sourceKey = '',
  });
  final String title, detail, status, tool;
  final String? target;
  final String? managedTaskId;
  final String? managedPlanId, managedResourceId;
  final String sourceKey;

  PersonalRecord? linkedTask(PersonalSpaceStore store) => managedTaskId != null
      ? store.task(managedTaskId!)
      : store.taskForSource(sourceKey);

  TaskResult displayTask(
    PersonalRecord? task, {
    TaskPlan? plan,
    Map<String, dynamic>? resource,
  }) => task == null || managedTaskId == null
      ? this
      : TaskResult(
          title: task.title,
          detail: [
            if (plan != null) ...[
              plan.ruleLabel,
              '下次：${planTime(plan.data['nextAt'])}',
              if (plan.lastRun != null)
                '最近：${runStateLabel(plan.lastRun!['state'])}',
            ] else if (resource != null) ...[
              resource['provider'] == 'calendar' ? '系统日历' : '手机时钟',
              if (resource['actual'] is Map)
                planTime((resource['actual'] as Map)['at']),
            ] else ...[
              if (task.date.isNotEmpty) task.date,
              if (task.time.isNotEmpty) task.time,
            ],
            '我的任务',
          ].join(' · '),
          status: plan != null
              ? plan.stateLabel
              : resource != null
              ? switch (resource['state']) {
                  'verified' => '系统提醒已核验',
                  'cancelled' => '系统提醒已取消',
                  'user_confirmed' => '用户已确认',
                  _ => '系统提醒待核对',
                }
              : task.archived
              ? '已归档'
              : task.done
              ? '已完成'
              : task.inProgress
              ? '进行中'
              : '待办已保存',
          tool: tool,
          managedTaskId: task.id,
          managedPlanId: plan?.id ?? managedPlanId,
          managedResourceId: managedResourceId,
          sourceKey: sourceKey,
        );

  Future<PersonalRecord> addToTasks(PersonalSpaceStore store) {
    if (sourceKey.isEmpty || managedTaskId != null)
      throw StateError('此结果已有任务或缺少有效回执。');
    return store.applyTask('attach', {
      'title': title,
      'body': '已完成的操作记录',
      'sourceKey': sourceKey,
      'sourceTarget': target ?? '',
      'sourceDetail': '$status${detail.isEmpty ? '' : ' · $detail'}',
    }, 'attach:$sourceKey');
  }

  static TaskResult? fromMessages(
    List<Message> messages, {
    String? phase,
    String goal = '',
  }) {
    if (phase != null && phase != 'done') return null;
    final steps = cloudExecutionSteps(messages);
    if (steps.isEmpty ||
        steps.any(
          (s) =>
              s.legacy || s.first.toolExecution!.tool.startsWith('assistant.'),
        ))
      return null;
    const navigation = {
      'apps.launch',
      'settings.open',
      'clock.alarms.show',
      'ui.back',
      'ui.home',
      'ui.scroll',
    };
    final work = steps
        .where(
          (s) =>
              !navigation.contains(s.first.toolExecution!.tool) &&
              !s.first.toolExecution!.tool.startsWith('coding.') &&
              !s.first.toolExecution!.tool.startsWith('adapter.'),
        )
        .toList();
    if (work.isEmpty ||
        work.any(
          (s) =>
              !{'verified', 'user_confirmed'}.contains(s.outcome) ||
              s.result?.toolExecution?.verification == 'process_exit' &&
                  s.outcome != 'user_confirmed',
        ))
      return null;
    final writes = work.where((step) {
      final event = step.result!.toolExecution!;
      var effect = event.effect;
      if (effect == null) {
        try {
          effect = deviceTool(event.tool).effect;
        } catch (_) {}
      }
      return const {'write', 'external'}.contains(effect);
    }).toList();
    if (writes.isEmpty) return null;
    final chosen =
        writes
            .where((s) => s.result?.toolExecution?.resultTitle != null)
            .lastOrNull ??
        writes.last;
    final event = chosen.result!.toolExecution!;
    final target =
        event.resultTarget ??
        switch (event.tool) {
          'clock.alarm.create' => 'clock.alarms',
          'clock.timer.start' => 'clock.timers',
          'settings.brightness.write' => 'settings.display',
          _ => null,
        } ??
        steps.reversed
            .where(
              (s) =>
                  {'verified', 'user_confirmed'}.contains(s.outcome) ||
                  navigation.contains(s.first.toolExecution!.tool) &&
                      s.outcome == 'dispatched',
            )
            .map((s) => s.result?.toolExecution?.resultTarget)
            .whereType<String>()
            .firstOrNull;
    return TaskResult(
      title:
          event.resultTitle ??
          (work.any((s) => s.outcome == 'user_confirmed') &&
                  goal.trim().isNotEmpty
              ? goal.trim()
              : chosen.purpose),
      detail: event.resultDetail ?? '',
      status: work.any((s) => s.outcome == 'user_confirmed') ? '你已确认完成' : '已完成',
      tool: event.tool,
      target: target,
      managedTaskId: event.managedTaskId,
      managedPlanId: event.managedPlanId,
      managedResourceId: event.managedResourceId,
      sourceKey:
          'execution:${sha256.convert(utf8.encode(jsonEncode([event.taskId, event.requestId])))}',
    );
  }
}

class TaskResultCard extends StatelessWidget {
  const TaskResultCard({
    super.key,
    required this.result,
    this.onOpen,
    this.opening = false,
    this.onManage,
    this.manageLabel = '加入任务',
    this.saving = false,
  });
  final TaskResult result;
  final VoidCallback? onOpen;
  final bool opening;
  final VoidCallback? onManage;
  final String manageLabel;
  final bool saving;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final icon = result.tool.startsWith('clock.alarm')
        ? Icons.alarm_outlined
        : result.tool.startsWith('clock.timer')
        ? Icons.timer_outlined
        : result.target?.contains('calendar') == true
        ? Icons.event_outlined
        : Icons.task_alt_outlined;
    return Semantics(
      container: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: colors.surface.withValues(alpha: .82),
          border: Border.all(
            color: colors.outlineVariant.withValues(alpha: .65),
          ),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: colors.onSurface.withValues(alpha: .045),
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Icon(icon, size: 22, color: colors.onSurfaceVariant),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        result.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.onSurface,
                          fontSize: 14,
                          height: 1.35,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        [
                          result.status,
                          if (result.detail.isNotEmpty) result.detail,
                        ].join(' · '),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.onSurfaceVariant,
                          fontSize: 12,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
                if (onOpen != null) ...[
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: opening ? null : onOpen,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: colors.onSurface,
                      side: BorderSide(color: colors.outlineVariant),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      minimumSize: const Size(52, 36),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(11),
                      ),
                    ),
                    child: Text(
                      opening
                          ? '打开中'
                          : result.managedTaskId != null
                          ? '查看任务'
                          : '打开',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ],
            ),
            if (onManage != null)
              Padding(
                padding: const EdgeInsets.only(left: 50, top: 3),
                child: TextButton.icon(
                  onPressed: saving ? null : onManage,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 0,
                      vertical: 4,
                    ),
                    minimumSize: const Size(0, 32),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  icon: Icon(
                    manageLabel == '加入任务'
                        ? Icons.playlist_add
                        : Icons.checklist_outlined,
                    size: 15,
                  ),
                  label: Text(
                    saving ? '正在保存' : manageLabel,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

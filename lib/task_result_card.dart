import 'package:flutter/material.dart';
import 'cloud_execution_disclosure.dart';
import 'state.dart';

/// A view of actual receipts. Rendering or restoring a card executes nothing.
class TaskResult {
  const TaskResult({
    required this.title,
    required this.detail,
    required this.status,
    required this.tool,
    this.target,
  });
  final String title, detail, status, tool;
  final String? target;

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
        .where((s) => !navigation.contains(s.first.toolExecution!.tool))
        .toList();
    if (work.isEmpty ||
        work.any(
          (s) =>
              !{'verified', 'user_confirmed'}.contains(s.outcome) ||
              s.result?.toolExecution?.verification == 'process_exit' &&
                  s.outcome != 'user_confirmed',
        ))
      return null;
    final chosen =
        work
            .where((s) => s.result?.toolExecution?.resultTitle != null)
            .lastOrNull ??
        work.last;
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
          (goal.trim().isEmpty ? chosen.purpose : goal.trim()),
      detail: event.resultDetail ?? '',
      status: work.any((s) => s.outcome == 'user_confirmed') ? '你已确认完成' : '已完成',
      tool: event.tool,
      target: target,
    );
  }
}

class TaskResultCard extends StatelessWidget {
  const TaskResultCard({
    super.key,
    required this.result,
    this.onOpen,
    this.opening = false,
  });
  final TaskResult result;
  final VoidCallback? onOpen;
  final bool opening;
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
        child: Row(
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
            if (result.target != null && onOpen != null) ...[
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
                  opening ? '打开中' : '打开',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'state.dart';

/// A view of the canonical transcript; grouping never edits or replays history.
class CloudTranscriptRow {
  CloudTranscriptRow(this.index, Message first, {this.execution = false})
    : messages = [first];

  final int index;
  final bool execution;
  final List<Message> messages;
  Message get first => messages.first;
  String? get taskId => messages
      .map((m) => m.toolExecution?.taskId)
      .whereType<String>()
      .firstOrNull;
}

List<CloudTranscriptRow> cloudTranscriptRows(
  List<Message> messages, {
  required bool cloud,
}) {
  final rows = <CloudTranscriptRow>[];
  for (var i = 0; i < messages.length; i++) {
    final message = messages[i];
    final execution = cloud && !message.user && message.toolReceipt;
    final previous = rows.lastOrNull;
    if (execution &&
        previous != null &&
        previous.execution &&
        previous.first.turnId == message.turnId &&
        (previous.taskId == null ||
            message.toolExecution == null ||
            previous.taskId == message.toolExecution!.taskId)) {
      previous.messages.add(message);
    } else {
      rows.add(CloudTranscriptRow(i, message, execution: execution));
    }
  }
  return rows;
}

class CloudExecutionStep {
  CloudExecutionStep(this.first);
  final Message first;
  Message? result;
  String? get requestId => first.toolExecution?.requestId;
  bool get legacy => first.toolExecution == null;
  String get purpose {
    final event = first.toolExecution;
    if (event == null) return '历史记录';
    return event.purpose.trim().isEmpty ? '执行操作' : event.purpose;
  }

  String? get outcome => result?.toolExecution?.outcome;
  String get summary {
    if (legacy) return first.text;
    final text = result?.text ?? '';
    final newline = text.indexOf('\n');
    return newline < 0 ? '' : text.substring(newline + 1).trim();
  }
}

List<CloudExecutionStep> cloudExecutionSteps(List<Message> messages) {
  final steps = <CloudExecutionStep>[];
  final byId = <String, CloudExecutionStep>{};
  for (final message in messages) {
    final event = message.toolExecution;
    if (event == null) {
      steps.add(CloudExecutionStep(message));
      continue;
    }
    final step = byId.putIfAbsent(event.requestId, () {
      final step = CloudExecutionStep(message);
      steps.add(step);
      return step;
    });
    // A resumed permission request keeps its request ID and updates the same
    // step, rather than displaying the retry as another completed operation.
    if (event.outcome != null) step.result = message;
  }
  return steps;
}

class CloudExecutionDisclosure extends StatelessWidget {
  const CloudExecutionDisclosure({
    super.key,
    required this.messages,
    required this.expanded,
    required this.onToggle,
    this.phase,
    this.pendingRequestId,
    this.onResume,
    this.onCapabilities,
  });

  final List<Message> messages;
  final bool expanded;
  final VoidCallback onToggle;
  final String? phase, pendingRequestId;
  final VoidCallback? onResume, onCapabilities;

  @override
  Widget build(BuildContext context) {
    final steps = cloudExecutionSteps(messages);
    final active = const {'thinking', 'executing', 'stopping'}.contains(phase);
    final permission = phase == 'permission';
    final failed = steps.where((s) => s.outcome == 'failed').lastOrNull;
    final uncertain =
        phase == 'unknown' ||
        steps.any((s) => s.outcome == 'unknown') ||
        (!active &&
            !permission &&
            phase != 'stopped' &&
            steps.any((s) => !s.legacy && s.outcome == null));
    final dispatched = steps.any((s) => s.outcome == 'dispatched');
    final legacy = steps.any((s) => s.legacy);
    final status = switch (phase) {
      'thinking' => '继续处理中',
      'executing' => '正在执行',
      'stopping' => '正在停止',
      'permission' => '等待授权',
      'unknown' => '待核对',
      'failed' => '未完成',
      'stopped' => '已停止',
      _ =>
        uncertain
            ? '待核对'
            : failed != null
            ? '有失败步骤'
            : legacy
            ? '历史记录'
            : steps.every((s) => s.outcome == 'verified')
            ? '已完成'
            : '已结束',
    };
    final count = legacy ? '${messages.length} 条记录' : '${steps.length} 个步骤';
    final current = steps
        .where((s) => s.requestId == pendingRequestId)
        .lastOrNull;
    final action = active || permission
        ? current?.purpose ?? steps.lastOrNull?.purpose
        : null;
    final alert = permission
        ? current?.summary.isNotEmpty == true
              ? current!.summary
              : '需要授权，任务已暂停。'
        : uncertain
        ? '有操作结果待核对，请先确认实际结果。'
        : failed != null
        ? failed.summary.isNotEmpty
              ? failed.summary
              : '有步骤未能完成，展开可查看记录。'
        : phase == 'failed'
        ? '本次执行未完成，具体原因见下方回复。'
        : dispatched
        ? '部分操作仅确认已派发，实际结果尚未验证。'
        : null;
    final color = sceneMuted;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          expanded: expanded,
          child: TextButton(
            key: ValueKey('execution-toggle-${messages.first.id}'),
            style: TextButton.styleFrom(
              foregroundColor: color,
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 8),
              minimumSize: const Size(0, 44),
              alignment: Alignment.centerLeft,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: onToggle,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  expanded ? Icons.expand_more : Icons.chevron_right,
                  size: 18,
                ),
                const SizedBox(width: 5),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '执行过程 · $status · $count',
                        style: const TextStyle(fontSize: 12, height: 1.5),
                      ),
                      if (action != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: Text(
                            action,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: sceneInk,
                              fontSize: 12,
                              height: 1.5,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        if (alert != null)
          Padding(
            key: ValueKey('execution-alert-${messages.first.id}'),
            padding: const EdgeInsets.fromLTRB(25, 2, 4, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  alert,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.5,
                    color: failed != null || phase == 'failed'
                        ? Theme.of(context).colorScheme.error
                        : sceneInk,
                  ),
                ),
                if (permission)
                  Wrap(
                    spacing: 8,
                    children: [
                      if (onCapabilities != null)
                        TextButton(
                          onPressed: onCapabilities,
                          child: const Text('查看授权'),
                        ),
                      if (onResume != null)
                        TextButton(
                          onPressed: onResume,
                          child: const Text('核对授权并继续'),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        if (expanded)
          Container(
            key: ValueKey('execution-steps-${messages.first.id}'),
            margin: const EdgeInsets.fromLTRB(10, 2, 4, 10),
            padding: const EdgeInsets.only(left: 13),
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(color: color.withValues(alpha: .25)),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < steps.length; i++)
                  _step(context, steps[i], i + 1, active, color),
              ],
            ),
          ),
      ],
    );
  }

  Widget _step(
    BuildContext context,
    CloudExecutionStep step,
    int number,
    bool active,
    Color color,
  ) {
    final executing =
        phase == 'executing' && step.requestId == pendingRequestId;
    final status = executing
        ? '执行中'
        : switch (step.outcome) {
            'verified' => '已验证',
            'dispatched' => '已派发',
            'permission_required' => '需要授权',
            'failed' => '未完成',
            'unknown' => '待核对',
            'cancelled' => '已取消',
            _ =>
              step.legacy
                  ? '历史记录'
                  : active && step.requestId == pendingRequestId
                  ? '执行中'
                  : phase == 'stopped'
                  ? '已停止 · 结果未确认'
                  : '待核对',
          };
    final icon = switch (step.outcome) {
      'verified' => Icons.check_circle_outline,
      'dispatched' => Icons.north_east,
      'permission_required' => Icons.lock_outline,
      'failed' => Icons.error_outline,
      'cancelled' => Icons.stop_circle_outlined,
      _ => Icons.more_horiz,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$number. ${step.purpose}',
                  style: TextStyle(fontSize: 12, height: 1.5, color: sceneInk),
                ),
                Text(
                  status,
                  style: TextStyle(fontSize: 11, height: 1.6, color: color),
                ),
                if (step.summary.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: SelectableText(
                      step.summary,
                      style: TextStyle(fontSize: 12, height: 1.6, color: color),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

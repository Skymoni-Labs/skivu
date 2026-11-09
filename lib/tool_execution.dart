/// Display-only metadata with bounded task labels/time summaries. Raw arguments,
/// screenshots and command output are not copied. Reading never dispatches tools.
class ToolExecutionEvent {
  const ToolExecutionEvent({
    required this.taskId,
    required this.requestId,
    required this.tool,
    required this.purpose,
    this.outcome,
    this.verification,
    this.resultTitle,
    this.resultDetail,
    this.resultTarget,
    this.effect,
    this.managedTaskId,
    this.managedPlanId,
    this.managedResourceId,
    this.artifactIds,
  });

  final String taskId, requestId, tool, purpose;
  final String? outcome;
  final String? verification;
  final String? resultTitle, resultDetail, resultTarget;
  final String? effect;
  final String? managedTaskId;
  final String? managedPlanId;
  final String? managedResourceId;
  final String? artifactIds;

  Map<String, String> toJson() => {
    'taskId': taskId,
    'requestId': requestId,
    'tool': tool,
    'purpose': purpose,
    if (outcome != null) 'outcome': outcome!,
    if (verification != null) 'verification': verification!,
    if (resultTitle != null) 'resultTitle': resultTitle!,
    if (resultDetail != null) 'resultDetail': resultDetail!,
    if (resultTarget != null) 'resultTarget': resultTarget!,
    if (effect != null) 'effect': effect!,
    if (managedTaskId != null) 'managedTaskId': managedTaskId!,
    if (managedPlanId != null) 'managedPlanId': managedPlanId!,
    if (managedResourceId != null) 'managedResourceId': managedResourceId!,
    if (artifactIds != null) 'artifactIds': artifactIds!,
  };

  static ToolExecutionEvent? parse(dynamic raw) {
    if (raw is! Map) return null;
    for (final key in ['taskId', 'requestId', 'tool', 'purpose']) {
      if (raw[key] is! String) return null;
    }
    if ((raw['taskId'] as String).isEmpty ||
        (raw['requestId'] as String).isEmpty ||
        (raw['tool'] as String).isEmpty)
      return null;
    final outcome = raw['outcome'];
    if (outcome != null &&
        !const {
          'verified',
          'dispatched',
          'permission_required',
          'failed',
          'unknown',
          'cancelled',
          'user_confirmed',
          'confirmation_required',
        }.contains(outcome))
      return null;
    return ToolExecutionEvent(
      taskId: raw['taskId'],
      requestId: raw['requestId'],
      tool: raw['tool'],
      purpose: raw['purpose'],
      artifactIds:
          raw['artifactIds'] is String &&
              RegExp(
                r'^artifact_[0-9a-f]{32}(,artifact_[0-9a-f]{32}){0,39}$',
              ).hasMatch(raw['artifactIds'])
          ? raw['artifactIds']
          : null,
      outcome: outcome as String?,
      verification: raw['verification'] == 'process_exit'
          ? 'process_exit'
          : null,
      resultTitle: displayText(raw['resultTitle'], 160),
      resultDetail: displayText(raw['resultDetail'], 240),
      effect: const {'read', 'write', 'external'}.contains(raw['effect'])
          ? raw['effect']
          : null,
      managedResourceId:
          raw['managedResourceId'] is String &&
              RegExp(
                r'^[a-zA-Z0-9_-]{1,100}$',
              ).hasMatch(raw['managedResourceId'])
          ? raw['managedResourceId']
          : null,
      managedPlanId:
          raw['managedPlanId'] is String &&
              RegExp(r'^[a-zA-Z0-9_-]{1,100}$').hasMatch(raw['managedPlanId'])
          ? raw['managedPlanId']
          : null,
      managedTaskId:
          raw['managedTaskId'] is String &&
              RegExp(r'^[a-zA-Z0-9_-]{1,100}$').hasMatch(raw['managedTaskId'])
          ? raw['managedTaskId']
          : null,
      resultTarget: validTarget(raw['resultTarget'])
          ? raw['resultTarget']
          : null,
    );
  }

  static String? displayText(dynamic value, int max) =>
      value is String &&
          value.trim().isNotEmpty &&
          value.length <= max &&
          !RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f]').hasMatch(value)
      ? value.trim()
      : null;

  static bool validTarget(dynamic value) =>
      value is String &&
      (const {
            'clock.alarms',
            'clock.timers',
            'settings.display',
          }.contains(value) ||
          RegExp(
                r'^app:[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*)+$',
              ).hasMatch(value) &&
              value.length <= 220);
}

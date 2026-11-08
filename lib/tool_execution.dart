/// Display-only metadata. Arguments, screenshots and raw command output are not
/// copied into the chat archive. Reading this record never dispatches a tool.
class ToolExecutionEvent {
  const ToolExecutionEvent({
    required this.taskId,
    required this.requestId,
    required this.tool,
    required this.purpose,
    this.outcome,
    this.verification,
  });

  final String taskId, requestId, tool, purpose;
  final String? outcome;
  final String? verification;

  Map<String, String> toJson() => {
    'taskId': taskId,
    'requestId': requestId,
    'tool': tool,
    'purpose': purpose,
    if (outcome != null) 'outcome': outcome!,
    if (verification != null) 'verification': verification!,
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
      outcome: outcome as String?,
      verification: raw['verification'] == 'process_exit'
          ? 'process_exit'
          : null,
    );
  }
}

import 'dart:async';
import 'dart:math';
import 'package:flutter/services.dart';
import 'assistant_engine.dart';
import 'cloud_coding_tools.dart';

/// One publication adapter for chat/headless execution. Widgets don't own jobs.
class CloudExecutionState {
  CloudExecutionState(this.engine, this.conversationId);
  final AssistantEngine engine;
  final String conversationId;
  final String source =
      '${DateTime.now().microsecondsSinceEpoch}_${Random.secure().nextInt(1 << 32)}';
  int sequence = 0;
  bool phone = false;
  String target = '';
  String _last = '';
  bool pauseRequested = false;
  Completer<void>? _pause;
  Future<void> checkpoint() async {
    if (pauseRequested) {
      _pause ??= Completer<void>();
      await _pause!.future;
    }
  }

  void resume() {
    pauseRequested = false;
    _pause?.complete();
    _pause = null;
    publish();
  }

  void requestPause() {
    pauseRequested = true;
    engine.requestPause();
    publish();
  }

  void publish() {
    if (engine.taskId.isEmpty) return;
    final tool = engine.pending?['tool']?.toString() ?? '';
    if (tool.startsWith('ui.') ||
        tool == 'apps.launch' ||
        tool.startsWith('clock.') ||
        tool == 'settings.open')
      phone = true;
    final args = engine.pending?['arguments'];
    if (args is Map) {
      if (args['package'] is String) target = args['package'];
      if (args['projectId'] is String) target = args['projectId'];
    }
    final resultMessages = engine.messages
        .where(
          (m) =>
              m['role'] == 'tool' &&
              m['taskId'] == engine.taskId &&
              m['outcome'] != null,
        )
        .toList();
    final lastResult = resultMessages.lastOrNull;
    final lastJob = engine.codingWorkspace['lastJob'];
    final checkedCoding =
        lastResult?['tool']?.startsWith('coding.') == true &&
        lastJob is Map &&
        lastJob['taskId'] == engine.taskId &&
        lastJob['state'] == 'exited' &&
        lastJob['exitCode'] == 0;
    final resolvedDiagnostics = resultMessages.asMap().entries.every(
      (entry) =>
          entry.value['outcome'] == 'verified' ||
          (entry.value['outcome'] == 'failed' ||
                  entry.value['tool'] == 'ui.verify' &&
                      entry.value['outcome'] == 'unknown') &&
              resultMessages
                  .skip(entry.key + 1)
                  .any(
                    (later) =>
                        later['tool'] == entry.value['tool'] &&
                        later['outcome'] == 'verified',
                  ),
    );
    final verified =
        engine.phase == 'done' &&
        !engine.hasUnverifiedEffects &&
        !engine.codingCheckFailed &&
        engine.activeCodingJobs.isEmpty &&
        resultMessages.isNotEmpty &&
        lastResult?['outcome'] == 'verified' &&
        (resolvedDiagnostics || checkedCoding || engine.finalDeliveryVerified);
    final phase = switch (engine.phase) {
      'thinking' => 'deciding',
      'executing' =>
        tool == 'ui.observe'
            ? 'observing'
            : tool == 'ui.wait'
            ? 'waiting'
            : 'acting',
      'paused' => 'paused',
      'permission' || 'confirmation' => 'waiting_user',
      'stopping' => 'stopping',
      'stopped' => 'stopped',
      'done' => verified ? 'completed' : 'result_ready',
      'failed' => 'failed',
      'unknown' || 'awaiting_verification' => 'unknown',
      _ => 'result_ready',
    };
    final action =
        engine.pending?['purpose'] ??
        (engine.phase == 'paused'
            ? '已暂停后续动作；已派发操作保持原结果。'
            : resultMessages.lastOrNull?['purpose'] ?? '');
    final key = '${engine.taskId}:$phase:$action:$target:$phone:$verified';
    if (key == _last) return;
    _last = key;
    unawaited(
      cloudExecutionChannel
          .invokeMethod('execution.update', {
            'taskId': engine.taskId,
            'conversationId': conversationId,
            'source': source,
            'sequence': ++sequence,
            'target': target,
            'goal': engine.goal,
            'phase': phase,
            'action': action,
            'phone': phone,
            'canStop':
                engine.running ||
                engine.canResume ||
                engine.phase == 'paused' ||
                engine.activeCodingJobs.isNotEmpty,
            'canPause': const {'thinking', 'executing'}.contains(engine.phase),
            'canResume': engine.phase == 'paused',
            'verified': verified,
            'evidence': verified ? '操作回执已核对；详见当前执行记录。' : '',
          })
          .catchError((_) {
            return null;
          }),
    );
  }

  void newTask() {
    phone = false;
    target = '';
    _last = '';
    pauseRequested = false;
    resume();
  }

  static const controls = MethodChannel('skivu/cloud_controls');
}

// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:convert';

typedef DeviceRequest =
    Future<Map<String, dynamic>> Function(
      String method,
      Map<String, dynamic> params,
    );
typedef DevicePlanner =
    Future<String> Function(
      Map<String, dynamic> observation,
      List<Map<String, dynamic>> receipts,
    );
typedef DeviceTaskUpdate = Future<void> Function(String state, String summary);

class DeviceTaskFailure implements Exception {
  const DeviceTaskFailure(this.code, this.message);
  final String code, message;
  @override
  String toString() => message;
}

class _FreshObservationRequired extends DeviceTaskFailure {
  const _FreshObservationRequired()
    : super('STALE_OBSERVATION', '目标界面已变化，需要重新观察。');
}

class DevicePlan {
  DevicePlan(
    this.done,
    this.summary,
    this.action,
    this.arguments,
    this.evidence,
  );
  final bool done;
  final String summary, action;
  final Map<String, dynamic> arguments;
  final List<String> evidence;
  static const actions = {
    'tap',
    'long_press',
    'input_text',
    'scroll',
    'swipe',
    'back',
    'home',
    'launch_app',
    'wait',
  };
  static DevicePlan parse(
    String text,
    Map<String, dynamic> observation,
    Set<String> apps,
  ) {
    if (text.length > 16000)
      throw const DeviceTaskFailure('INVALID_PLAN', '模型计划过长。');
    final Object? raw;
    try {
      raw = jsonDecode(text);
    } catch (_) {
      throw const DeviceTaskFailure('INVALID_PLAN', '模型没有返回完整 JSON。');
    }
    if (raw is! Map ||
        raw.length != 5 ||
        raw['done'] is! bool ||
        raw['summary'] is! String ||
        (raw['summary'] as String).length > 1000 ||
        raw['action'] is! String ||
        raw['arguments'] is! Map ||
        raw['evidenceIds'] is! List) {
      throw const DeviceTaskFailure('INVALID_PLAN', '模型计划字段无效。');
    }
    final nodes = ((observation['tree'] as Map?)?['elements'] as List? ?? [])
        .whereType<Map>()
        .toList();
    final ids = nodes.map((n) => n['element_id']).whereType<String>().toSet();
    final evidence = raw['evidenceIds'] as List;
    if (evidence.length > 10 ||
        evidence.any((e) => e is! String || !ids.contains(e)))
      throw const DeviceTaskFailure('INVALID_PLAN', '完成依据不属于当前界面。');
    final done = raw['done'] as bool, action = raw['action'] as String;
    final args = Map<String, dynamic>.from(raw['arguments'] as Map);
    if (done) {
      if (action.isNotEmpty ||
          args.isNotEmpty ||
          evidence.isEmpty ||
          (raw['summary'] as String).trim().isEmpty)
        throw const DeviceTaskFailure('INVALID_PLAN', '完成计划需要当前界面依据。');
    } else {
      if (!actions.contains(action))
        throw const DeviceTaskFailure('INVALID_PLAN', '模型提出了不受支持的操作。');
      const keys = <String, Set<String>>{
        'tap': {'element_id', 'x', 'y'},
        'long_press': {'element_id', 'x', 'y', 'duration_ms'},
        'input_text': {'element_id', 'text', 'mode'},
        'scroll': {'element_id', 'region', 'direction'},
        'swipe': {'points', 'duration_ms'},
        'launch_app': {'package_name'},
        'wait': {'timeout_ms'},
        'back': {},
        'home': {},
      };
      if (args.keys.any((k) => !keys[action]!.contains(k)))
        throw const DeviceTaskFailure('INVALID_PLAN', '模型试图指定执行器保留字段。');
      if (args.containsKey('element_id') && !ids.contains(args['element_id']))
        throw const DeviceTaskFailure('INVALID_PLAN', '模型选择了不存在的控件。');
      if (action == 'launch_app' && !apps.contains(args['package_name']))
        throw const DeviceTaskFailure('INVALID_PLAN', '目标软件未授权。');
      if (action == 'input_text' &&
          (args['element_id'] is! String ||
              args['text'] is! String ||
              (args['text'] as String).length > 4000 ||
              !{'replace', 'insert'}.contains(args['mode'])))
        throw const DeviceTaskFailure('INVALID_PLAN', '输入参数无效。');
      if ({'tap', 'long_press'}.contains(action) &&
          !args.containsKey('element_id') &&
          !(args['x'] is num && args['y'] is num))
        throw const DeviceTaskFailure('INVALID_PLAN', '缺少点击目标。');
      if (action == 'wait' &&
          (args['timeout_ms'] is! int ||
              args['timeout_ms'] < 100 ||
              args['timeout_ms'] > 5000))
        throw const DeviceTaskFailure('INVALID_PLAN', '等待时间无效。');
    }
    return DevicePlan(
      done,
      raw['summary'],
      action,
      args,
      evidence.cast<String>(),
    );
  }
}

/// Model-independent execution. Observations/actions never survive a process restart.
class DeviceTaskRunner {
  DeviceTaskRunner({
    required this.id,
    required this.request,
    required this.plan,
    required this.update,
    required this.check,
    required this.waitForConfirmation,
    required this.apps,
    required this.maxActions,
    required this.maxRounds,
    required this.deadline,
  });
  final String id;
  final DeviceRequest request;
  final DevicePlanner plan;
  final DeviceTaskUpdate update;
  final void Function() check;
  final Future<void> Function() waitForConfirmation;
  final Set<String> apps;
  final int maxActions, maxRounds;
  final DateTime deadline;
  String? capability;
  int count = 0, rounds = 0;
  int refreshes = 0;
  String? failureCode;
  bool cancelled = false;
  final receipts = <Map<String, dynamic>>[];
  void guard() {
    check();
    if (cancelled) throw const DeviceTaskFailure('CANCELLED', '任务已停止。');
    if (DateTime.now().isAfter(deadline))
      throw const DeviceTaskFailure('TIME_LIMIT', '任务已达到时间上限。');
  }

  Map<String, dynamic> validated(Map<String, dynamic> result) {
    if (result['error'] is Map) {
      final error = result['error'] as Map;
      throw DeviceTaskFailure(
        error['code']?.toString() ?? 'DEVICE_FAILED',
        error['message']?.toString() ?? '设备未完成操作。',
      );
    }
    return result;
  }

  Future<Map<String, dynamic>> call(
    String name,
    Map<String, dynamic> args,
  ) async {
    guard();
    final result = await request('call', {
      'taskCapability': capability,
      'name': name,
      'arguments': args,
    });
    guard();
    return result;
  }

  Future<void> execute(String name, Map<String, dynamic> args) async {
    if (count >= maxActions)
      throw const DeviceTaskFailure('ACTION_LIMIT', '已达到操作次数上限。');
    final rid = '$id:${++count}';
    final input = {...args, 'request_id': rid};
    await update('executing', '第 $count 步：$name');
    var result = await call(name, input);
    if ((result['error'] as Map?)?['code'] == 'CONFIRM_REQUIRED') {
      await update('awaiting_confirmation', '这一步需要你在设备伴侣中确认。');
      await waitForConfirmation();
      guard();
      result = await call(
        name,
        input,
      ); // Same identity; the first call was rejected before dispatch.
    }
    final code = (result['error'] as Map?)?['code'];
    if ({
          'STALE_OBSERVATION',
          'STALE_ELEMENT',
          'STALE_TARGET',
          'TARGET_CHANGED',
        }.contains(code) &&
        result['state'] == 'failed' &&
        result['action_executed'] == false) {
      receipts.add({
        'step': count,
        'action': name,
        'state': 'rejected',
        'actionExecuted': false,
        'errorCode': code,
      });
      throw const _FreshObservationRequired();
    }
    validated(result);
    final end = DateTime.now().add(const Duration(seconds: 25));
    while ({'accepted', 'executing'}.contains(result['state'])) {
      if (DateTime.now().isAfter(end))
        throw const DeviceTaskFailure(
          'RESULT_UNKNOWN',
          '操作仍未收到最终回执，请核对，不要重复执行。',
        );
      await Future<void>.delayed(const Duration(milliseconds: 250));
      guard();
      result = validated(await call('get_status', {'request_id': rid}));
      if (result['request'] is Map)
        result = Map<String, dynamic>.from(result['request'] as Map);
    }
    if (result['state'] != 'executed' || result['action_executed'] != true)
      throw const DeviceTaskFailure('RESULT_UNKNOWN', '没有取得明确执行回执，任务已暂停核对。');
    receipts.add({
      'step': count,
      'action': name,
      'state': result['state'],
      'actionExecuted': true,
    });
    if (receipts.length > 8) receipts.removeAt(0);
  }

  Future<void> run() async {
    try {
      guard();
      await update('connecting', '正在取得本次任务的设备授权。');
      final lease = validated(
        await request('begin', {
          'allowedPackages': apps.toList(),
          'maxActions': maxActions,
          'timeoutMs': deadline
              .difference(DateTime.now())
              .inMilliseconds
              .clamp(1000, 600000),
        }),
      );
      capability = lease['taskCapability'] as String;
      guard();
      await execute('launch_app', {'package_name': apps.first});
      while (rounds < maxRounds) {
        guard();
        await update('observing', '正在读取任务软件的当前界面。');
        final observation = validated(
          await call('observe', {
            'mode': 'tree',
            'output': 'decision',
            'compact': true,
            'stable_wait_ms': 300,
          }),
        );
        if (!apps.contains(observation['package_name']))
          throw const DeviceTaskFailure('APP_OUT_OF_SCOPE', '当前软件不属于任务范围。');
        await update('planning', '正在规划第 ${rounds + 1} 轮操作。');
        final text = await plan(observation, List.of(receipts));
        guard();
        rounds++;
        final next = DevicePlan.parse(text, observation, apps);
        if (next.done) {
          await update('completed', next.summary);
          return;
        }
        if (next.action == 'wait') {
          await Future<void>.delayed(
            Duration(milliseconds: next.arguments['timeout_ms']),
          );
          continue;
        }
        try {
          await execute(next.action, {
            ...next.arguments,
            if (!{'launch_app', 'home', 'back'}.contains(next.action))
              'observation_id': observation['observation_id'],
            'service_instance_id': observation['service_instance_id'],
          });
        } on _FreshObservationRequired {
          if (++refreshes > 2)
            throw const DeviceTaskFailure(
              'STALE_OBSERVATION',
              '界面持续变化，已停止后续操作，请人工核对。',
            );
          await update('observing', '上一步确认未执行；正在重新观察并规划，不重放旧动作。');
        }
      }
      throw const DeviceTaskFailure('MODEL_LIMIT', '已达到模型规划次数上限。');
    } on DeviceTaskFailure catch (e) {
      failureCode = e.code;
      await update(
        e.code == 'CANCELLED'
            ? 'cancelled'
            : {'RESULT_UNKNOWN', 'UNCERTAIN'}.contains(e.code)
            ? 'review_required'
            : 'failed',
        e.message,
      );
    } catch (_) {
      await update(
        cancelled ? 'cancelled' : 'review_required',
        cancelled ? '任务已停止；已经注入系统的操作可能完成，请按需核对。' : '任务中断，请核对已完成的操作；不会自动重放。',
      );
    } finally {
      if (capability != null) {
        try {
          await request('end', {'taskCapability': capability});
        } catch (_) {}
      }
    }
  }

  Future<void> cancel() async {
    cancelled = true;
    if (capability != null) {
      try {
        await request('end', {'taskCapability': capability});
      } catch (_) {}
    }
  }
}

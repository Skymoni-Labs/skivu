import 'assistant_engine.dart';
import 'assistant_task_tools.dart';
import 'device_engine.dart';
import 'open_plugin_tools.dart';
import 'task_plans.dart';
import 'assistant_reminder_tools.dart';

class AssistantPlanTools implements AssistantExtensions {
  AssistantPlanTools(
    this.tasks,
    this.plans, {
    required this.modelIdentity,
    required this.modelName,
    this.reminders,
    this.modelBinding,
  });
  final AssistantTaskTools tasks;
  final TaskPlans plans;
  final String Function() modelIdentity, modelName;
  final AssistantReminderTools? reminders;
  final Map<String, dynamic> Function()? modelBinding;
  static final _text = AssistantTaskTools.text;
  static final rule = {
    'type': 'object',
    'additionalProperties': false,
    'required': ['kind'],
    'properties': {
      'kind': {
        'type': 'string',
        'enum': ['once', 'daily', 'weekly', 'interval'],
      },
      'at': {'type': 'integer'},
      'time': _text(5),
      'timeZone': _text(80),
      'followDeviceZone': {'type': 'boolean'},
      'weekdays': {
        'type': 'array',
        'maxItems': 7,
        'items': {'type': 'integer'},
      },
      'intervalMinutes': {'type': 'integer'},
    },
  };
  static final fields = <String, dynamic>{
    'mode': {
      'type': 'string',
      'enum': ['summary', 'local_tasks', 'device_action'],
      'description':
          'summary=整理或生成内容，local_tasks=实际管理待办，device_action=实际手机操作（必须取得对应业务回执才算成功）',
    },
    'goal': _text(4000),
    'rule': rule,
    'maxRequestsPerRun': {'type': 'integer'},
    'maxDailyRequests': {'type': 'integer'},
    'maxOutputTokens': {'type': 'integer'},
    'maxDelayMinutes': {'type': 'integer'},
    'missedPolicy': {
      'type': 'string',
      'enum': ['latest', 'skip'],
    },
  };
  static final identity = {
    'id': _text(100),
    'expectedRevision': {'type': 'integer'},
  };
  static final definitions = {
    'list': AssistantTaskTools.definition(
      '查询后台定时计划，返回状态、下次时间、最近一次结果及用量上限；不返回工具历史。',
      'read',
      {'taskId': _text(100)},
    ),
    'get': AssistantTaskTools.definition(
      '读取定时计划的真实 id 和 version。',
      'read',
      {'id': _text(100)},
      ['id'],
    ),
    'create': AssistantTaskTools.definition(
      '用户明确要求到时间由小云处理事情时创建真实后台计划。先保存待办再传 taskId。准点提醒使用系统提醒，不用此接口。一次性用 rule.kind=once 和 at(UTC毫秒)，每天用daily/time，每周weekly/time/weekdays(周一1..周日7)，间隔interval/intervalMinutes最少15分钟。后台允许系统延迟，不保证准点。使用当前选定模型；每次和每日请求次数有限。',
      'write',
      {
        'taskId': _text(100),
        ...fields,
        'enabled': {'type': 'boolean'},
      },
      ['taskId', 'goal', 'rule', 'mode'],
    ),
    'update': AssistantTaskTools.definition(
      '修改原定时计划，不创建第二条。先 get 读取当前 version，用 expectedRevision；修改模型绑定会采用当前选定模型。',
      'write',
      {
        ...identity,
        ...fields,
        'useCurrentModel': {'type': 'boolean'},
      },
      ['id', 'expectedRevision'],
    ),
    'pause': AssistantTaskTools.definition(
      '暂停后续触发，保留事项和最近结果；当前已经派发的结果仍需核对。',
      'write',
      identity,
      ['id', 'expectedRevision'],
    ),
    'resume': AssistantTaskTools.definition(
      '重新启用原计划；已过期的单次计划需要先改为未来时间。不会补做一串过期执行。',
      'write',
      identity,
      ['id', 'expectedRevision'],
    ),
    'cancel': AssistantTaskTools.definition(
      '结束原后台计划并停止后续触发。仅停止这条后台计划，不删除系统提醒。',
      'write',
      identity,
      ['id', 'expectedRevision'],
    ),
  };
  @override
  Future<List<Map<String, dynamic>>> catalog() async => [
    ...await tasks.catalog(),
    ...await reminders?.catalog() ?? [],
    if (plans.supported)
      for (final d in definitions.entries)
        {
          'id': 'tasks.plan.${d.key}',
          ...d.value,
          'available': true,
          'source': '小云定时计划',
        },
  ];
  @override
  Future<Map<String, dynamic>> cancel() => tasks.cancel();
  @override
  Future<DeviceToolReceipt> invoke(
    String tool,
    Map<String, dynamic> args,
    String requestId,
    void Function() check,
  ) async {
    if (tool.startsWith('tasks.reminder.'))
      return (reminders ?? (throw StateError('系统提醒不可用。'))).invoke(
        tool,
        args,
        requestId,
        check,
      );
    if (!tool.startsWith('tasks.plan.'))
      return tasks.invoke(tool, args, requestId, check);
    final action = tool.substring('tasks.plan.'.length),
        definition = definitions[tool.substring('tasks.plan.'.length)];
    if (definition == null) throw const FormatException('定时工具不存在。');
    validatePluginArguments(args, definition['parameters'] as Map);
    check();
    try {
      await plans.refresh();
      check();
      Map<String, dynamic> value;
      if (action == 'list') {
        value = {
          'plans': [
            for (final p in plans.records)
              if (args['taskId'] == null || p.taskId == args['taskId']) p.data,
          ],
        };
      } else if (action == 'get') {
        value = await plans.database.call('plans.get', args);
      } else {
        final actual = {...args};
        if (action == 'create' || actual.remove('useCurrentModel') == true) {
          actual['modelIdentity'] = modelIdentity();
          actual['modelName'] = modelName();
          if (modelBinding != null) actual['modelBinding'] = modelBinding!();
        }
        value = await plans.operate('plans.$action', actual, requestId);
        // Return the associated task ID explicitly; this is not an external system ID.
        value = {...value, 'managedTaskId': value['taskId']};
      }
      return DeviceToolReceipt({
        'requestId': requestId,
        'tool': tool,
        'outcome': 'verified',
        'summary': action == 'list' || action == 'get'
            ? '已读取真实计划。'
            : '后台计划已保存，按记录的状态触发；实际时间允许系统延迟。',
        'value': value,
      });
    } catch (e) {
      check();
      return DeviceToolReceipt({
        'requestId': requestId,
        'tool': tool,
        'outcome': 'failed',
        'summary': '$e',
      });
    }
  }
}

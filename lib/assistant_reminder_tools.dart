import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'assistant_engine.dart';
import 'assistant_task_tools.dart';
import 'device_engine.dart';
import 'open_plugin_tools.dart';
import 'personal_space.dart';
import 'task_plans.dart';

class AssistantReminderTools implements AssistantExtensions {
  AssistantReminderTools(this.store, this.plans);
  final PersonalSpaceStore store;
  final TaskPlans plans;
  static final text = AssistantTaskTools.text;
  static final fields = <String, dynamic>{
    'title': text(160),
    'at': {'type': 'integer'},
    'timeZone': text(80),
    'reminderMinutes': {'type': 'integer'},
    'repeat': {
      'type': 'string',
      'enum': ['none', 'daily', 'weekly'],
    },
    'weekdays': {
      'type': 'array',
      'maxItems': 7,
      'items': {'type': 'integer'},
    },
  };
  static final identity = <String, dynamic>{
    'id': text(100),
    'expectedRevision': {'type': 'integer'},
    'expectedTag': text(64),
  };
  static final definitions = {
    'calendars': AssistantTaskTools.definition(
      '读取实际可写的系统日历，返回真实 calendarId；不能编造日历或对象编号。',
      'read',
      {},
    ),
    'list': AssistantTaskTools.definition(
      '查询保存的系统提醒关联；clock 没有通用对象编号时仍为待核对，不代表不存在。',
      'read',
      {'taskId': text(100)},
    ),
    'get': AssistantTaskTools.definition(
      '读取关联及实际系统日历对象、最新 revision、actual.tag。必须先读取再修改或取消。',
      'read',
      {'id': text(100)},
      ['id'],
    ),
    'create': AssistantTaskTools.definition(
      '用户明确要求提醒时，为已保存的任务在手机系统日历中登记事件和真实提醒，后台不跳软件。at 是未来 UTC毫秒；repeat 可 none/daily/weekly。需要日历授权和实际可写日历。这里只登记系统提醒，不是小云自建闹钟。已有不明提醒不会再新建替代。',
      'write',
      {
        'taskId': text(100),
        'calendarId': {'type': 'integer'},
        ...fields,
      },
      ['taskId', 'at'],
    ),
    'update': AssistantTaskTools.definition(
      '修改原关联对象，不能找不到原闹钟就新建。系统日历用实际 id、expectedRevision 和 actual.tag 作 expectedTag。时钟不能直接读写时只记录待核对请求，必须在真实授权界面定位唯一匹配项处理并核对，不能称已完成。',
      'write',
      {...identity, ...fields},
      ['id', 'expectedRevision'],
    ),
    'cancel': AssistantTaskTools.definition(
      '取消这条实际系统提醒。日历按真实对象 id 删除后读取核对；时钟不支持可靠定位时保留待核对，不能冒充已取消。不删除待办事项。',
      'write',
      identity,
      ['id', 'expectedRevision'],
    ),
    'verify': AssistantTaskTools.definition(
      '只读取核对原系统对象，不重新创建或重发修改。无法核验时保持待核对。',
      'read',
      {'id': text(100)},
      ['id'],
    ),
  };
  @override
  Future<List<Map<String, dynamic>>> catalog() async => plans.supported
      ? [
          for (final d in definitions.entries)
            {
              'id': 'tasks.reminder.${d.key}',
              ...d.value,
              'available': true,
              'source': '系统提醒关联',
            },
        ]
      : [];
  @override
  Future<Map<String, dynamic>> cancel() async => {'outcome': 'cancelled'};
  @override
  Future<DeviceToolReceipt> invoke(
    String tool,
    Map<String, dynamic> args,
    String requestId,
    void Function() check,
  ) async {
    final action = tool.substring('tasks.reminder.'.length),
        definition = definitions[tool.substring('tasks.reminder.'.length)];
    if (definition == null) throw const FormatException('提醒工具不存在。');
    validatePluginArguments(args, definition['parameters'] as Map);
    check();
    try {
      Map<String, dynamic> value;
      if (action == 'calendars')
        value = await plans.database.call('resources.calendars');
      else if (action == 'list') {
        await plans.refresh();
        check();
        final taskId = args['taskId'] as String?;
        final task = taskId == null ? null : store.task(taskId);
        if (taskId != null && task == null)
          throw const FormatException('待办不存在，请重新查询。');
        final sourceKey = task?.sourceKey;
        value = {
          'resources': [
            for (final r in plans.resources)
              if (taskId == null ||
                  r['taskId'] == taskId ||
                  (sourceKey != null &&
                      sourceKey.isNotEmpty &&
                      sourceKey == r['sourceKey']))
                r,
          ],
        };
      } else {
        value = await plans.database.call('resources.$action', {
          'arguments': args,
          'requestId': requestId,
        });
        await plans.refresh();
        check();
        final linked = value['taskId'] is String
            ? value['taskId']
            : store.taskForSource(value['sourceKey'] as String? ?? '')?.id;
        value = {...value, if (linked != null) 'managedTaskId': linked};
      }
      final verified =
          action == 'list' ||
          action == 'calendars' ||
          {'verified', 'cancelled'}.contains(value['state']);
      return DeviceToolReceipt({
        'requestId': requestId,
        'tool': tool,
        'outcome': verified ? 'verified' : 'dispatched',
        'summary': value['summary'] ?? '系统提醒关联已读取。',
        'value': value,
      });
    } on PlatformException catch (e) {
      check();
      return DeviceToolReceipt({
        'requestId': requestId,
        'tool': tool,
        'outcome': e.message?.contains('请先允许') == true
            ? 'permission_required'
            : 'failed',
        'summary': e.message ?? '系统提醒尚未处理，请核对原对象。',
      });
    }
  }

  Future<void> capture(
    String tool,
    Map<String, dynamic> args,
    Map<String, dynamic> receipt,
    String taskId,
    String requestId,
  ) async {
    if (!plans.supported ||
        tool != 'clock.alarm.create' ||
        !{'dispatched', 'verified'}.contains(receipt['outcome']))
      return;
    await plans.database.call('resources.captureClock', {
      'sourceKey': source(taskId, requestId),
      'arguments': args,
    });
    await plans.refresh();
  }

  Future<void> confirm(String taskId, String requestId) async {
    if (!plans.supported) return;
    await plans.database.call('resources.confirmClock', {
      'sourceKey': source(taskId, requestId),
    });
    await plans.refresh();
  }

  static String source(String taskId, String requestId) =>
      'execution:${sha256.convert(utf8.encode(jsonEncode([taskId, requestId])))}';
}

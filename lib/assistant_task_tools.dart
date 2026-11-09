import 'assistant_engine.dart';
import 'device_engine.dart';
import 'open_plugin_tools.dart';
import 'personal_space.dart';

/// Local task records share the same atomic store as Today and Tasks.
/// Dates are metadata: these tools never register a reminder or execute a device action.
class AssistantTaskTools implements AssistantExtensions {
  AssistantTaskTools(this.store);
  final PersonalSpaceStore store;
  static Map<String, dynamic> text(int max) => {
    'type': 'string',
    'maxLength': max,
  };
  static final fields = <String, dynamic>{
    'title': text(160),
    'body': text(12000),
    'date': text(10),
    'time': text(5),
    'category': text(40),
  };
  static final identity = <String, dynamic>{
    'id': text(100),
    'expectedRevision': {'type': 'integer'},
  };
  static final definitions = <String, Map<String, dynamic>>{
    'list': definition('查询任务，支持关键词、状态、日期及分页。只返回本页摘要；需要完整正文时 get。', 'read', {
      'query': text(160),
      'status': {
        'type': 'string',
        'enum': ['pending', 'done', 'archived', 'all'],
      },
      'date': text(10),
      'offset': {'type': 'integer'},
      'limit': {'type': 'integer'},
    }),
    'get': definition(
      '读取一条任务的实际内容、状态和最新 revision。',
      'read',
      {'id': text(100)},
      ['id'],
    ),
    'create': definition(
      '用户明确要记待办时新增任务。date 为 YYYY-MM-DD，time 为 HH:mm；仅保存安排，不启用提醒或定时执行。普通临时操作无需记录。',
      'write',
      fields,
      ['title'],
    ),
    'update': definition(
      '修改已读取的任务；必须使用实际 id 和最新 expectedRevision。仅改本地记录，不修改系统闹钟、日历或其他软件。',
      'write',
      {...identity, ...fields},
      ['id', 'expectedRevision'],
    ),
    'complete': definition(
      '明确设为完成或未完成（done）；不会翻转状态或再次执行原操作。',
      'write',
      {
        ...identity,
        'done': {'type': 'boolean'},
      },
      ['id', 'expectedRevision', 'done'],
    ),
    'archive': definition(
      '设为归档或恢复；只处理本地记录，不删除或取消系统软件中的对象。',
      'write',
      {
        ...identity,
        'archived': {'type': 'boolean'},
      },
      ['id', 'expectedRevision', 'archived'],
    ),
  };
  static Map<String, dynamic> definition(
    String description,
    String effect,
    Map<String, dynamic> properties, [
    List<String> required = const [],
  ]) => {
    'description': description,
    'effect': effect,
    'parameters': {
      'type': 'object',
      'properties': properties,
      'required': required,
      'additionalProperties': false,
    },
  };

  @override
  Future<List<Map<String, dynamic>>> catalog() async => [
    for (final entry in definitions.entries)
      {
        'id': 'tasks.${entry.key}',
        ...entry.value,
        'available': true,
        'source': '我的任务',
      },
  ];

  @override
  Future<Map<String, dynamic>> cancel() async => {'outcome': 'cancelled'};

  @override
  Future<DeviceToolReceipt> invoke(
    String tool,
    Map<String, dynamic> args,
    String requestId,
    void Function() check,
  ) async {
    check();
    final action = tool.startsWith('tasks.') ? tool.substring(6) : '';
    final definition = definitions[action];
    if (definition == null) throw const FormatException('任务工具不存在。');
    validatePluginArguments(args, definition['parameters'] as Map);
    if (args['expectedRevision'] != null &&
        (args['expectedRevision'] as int) < 1)
      throw const FormatException('任务版本无效。');
    await store.restore();
    check();
    if (store.error != null) throw StateError(store.error!);
    try {
      Object value;
      if (action == 'list') {
        final offset = args['offset'] as int? ?? 0,
            limit = args['limit'] as int? ?? 20;
        if (offset < 0 || limit < 1 || limit > 50)
          throw const FormatException('任务分页范围无效。');
        final status = args['status'] as String? ?? 'pending';
        final query = (args['query'] as String? ?? '').trim().toLowerCase();
        final date = args['date'] as String? ?? '';
        if (date.isNotEmpty && !validPersonalDay(date))
          throw const FormatException('任务日期无效。');
        final rows =
            [...store.tasks, ...store.archivedTasks]
                .where(
                  (r) =>
                      (status == 'all' ||
                          (status == 'archived'
                              ? r.archived
                              : !r.archived && r.done == (status == 'done'))) &&
                      (date.isEmpty || r.date == date) &&
                      (query.isEmpty ||
                          '${r.title}\n${r.body}'.toLowerCase().contains(
                            query,
                          )),
                )
                .toList()
              ..sort((a, b) => b.updated.compareTo(a.updated));
        value = {
          'total': rows.length,
          'offset': offset,
          'hasMore': offset + limit < rows.length,
          'tasks': [
            for (final r in rows.skip(offset).take(limit))
              {
                ...r.toJson(),
                'body': r.body.length > 240
                    ? '${r.body.substring(0, 240)}…'
                    : r.body,
              },
          ],
          'reminderEnabled': false,
        };
      } else if (action == 'get') {
        final record = store.task(args['id'] as String);
        if (record == null) throw StateError('没有找到这条任务。');
        value = record.toJson();
      } else {
        value = (await store.applyTask(
          action,
          args,
          requestId,
          check: check,
        )).toJson();
      }
      return DeviceToolReceipt({
        'requestId': requestId,
        'tool': tool,
        'outcome': 'verified',
        'summary': definition['effect'] == 'read'
            ? '已读取我的任务。'
            : '本地任务记录已保存。日期和时间不代表已启用提醒；未调用系统软件。',
        'value': value,
      });
    } on StateError catch (e) {
      check();
      return DeviceToolReceipt({
        'requestId': requestId,
        'tool': tool,
        'outcome': 'failed',
        'summary': '${e.message} 请先重新读取任务后处理。',
      });
    }
  }
}

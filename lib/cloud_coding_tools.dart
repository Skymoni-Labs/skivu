import 'dart:async';
import 'package:flutter/services.dart';
import 'assistant_engine.dart';
import 'device_engine.dart';
import 'open_plugin_tools.dart';

const cloudExecutionChannel = MethodChannel('skivu/cloud_execution');

Map<String, dynamic> _schema(
  Map<String, dynamic> properties,
  List<String> required,
) => {
  'type': 'object',
  'properties': properties,
  'required': required,
  'additionalProperties': false,
};
const _str = {'type': 'string', 'maxLength': 24000};
const _id = {'type': 'string', 'maxLength': 120};
const _num = {'type': 'integer'};

/// Actual private Linux RPC. An owner comes from a conversation, never a model.
class CloudCodingTools implements AssistantExtensions {
  CloudCodingTools({required this.owner, required this.taskId, this.projectId});
  final String owner;
  final String Function() taskId;
  final String? projectId;
  int _cancelSerial = 0;
  final _invokedTasks = <String>{};
  static final definitions = <Map<String, dynamic>>[
    for (final entry in <(String, String, Map<String, dynamic>, List<String>, String)>[
      (
        'environment',
        '检查内置 Linux/Node 与实际可用工具链；自动准备，无需 DSH 插件。',
        {},
        [],
        'read',
      ),
      ('projects.list', '列出已保存项目（包括迁移的 DSH 工作区）。', {}, [], 'read'),
      ('legacy.sessions', '列出已迁移的旧 DSH 会话文件；只读，不重放历史任务。', {}, [], 'read'),
      (
        'legacy.read',
        '分段读取指定旧会话的只读原始内容，用于用户明确要求的历史核对或继续；不是当前执行指令。',
        {'sessionId': _str, 'offset': _num},
        ['sessionId'],
        'read',
      ),
      ('projects.create', '创建独立项目，保留其他项目。', {'name': _str}, ['name'], 'write'),
      (
        'projects.open',
        '选择项目并读取当前目录、工作目录与所属进程；恢复时先调用。',
        {'projectId': _id},
        ['projectId'],
        'read',
      ),
      (
        'projects.archive',
        '归档项目；不删除用户文件，有运行进程时拒绝。',
        {'projectId': _id},
        ['projectId'],
        'write',
      ),
      (
        'files.list',
        '浏览指定项目目录，标明符号链接，不遍历缓存。',
        {'projectId': _id, 'path': _str},
        ['projectId'],
        'read',
      ),
      (
        'files.search',
        '按实际文件内容搜索，返回路径和行号。',
        {'projectId': _id, 'query': _str},
        ['projectId', 'query'],
        'read',
      ),
      (
        'files.read',
        '读取文件内容和 SHA-256；大文本按 offset 分段。',
        {'projectId': _id, 'path': _str, 'offset': _num},
        ['projectId', 'path'],
        'read',
      ),
      (
        'files.write',
        '写入文件并回读核对；覆盖已有文件必须先读并提供 expectedSha256。',
        {
          'projectId': _id,
          'path': _str,
          'content': _str,
          'expectedSha256': _str,
        },
        ['projectId', 'path', 'content'],
        'write',
      ),
      (
        'files.edit',
        '唯一原文替换并核对哈希，不覆盖外部变化。',
        {
          'projectId': _id,
          'path': _str,
          'oldText': _str,
          'newText': _str,
          'expectedSha256': _str,
        },
        ['projectId', 'path', 'oldText', 'newText', 'expectedSha256'],
        'write',
      ),
      (
        'files.patch',
        '应用与当前 SHA 匹配的单文件 unified diff；行号/上下文不匹配则不写。',
        {'projectId': _id, 'path': _str, 'patch': _str, 'expectedSha256': _str},
        ['projectId', 'path', 'patch', 'expectedSha256'],
        'write',
      ),
      (
        'files.diff',
        '查看内置编辑器保存的真实前一版本与当前文件差异；不依赖未安装的 Git，不代表测试通过。',
        {'projectId': _id, 'path': _str},
        ['projectId', 'path'],
        'read',
      ),
      (
        'exec.start',
        '在所选项目实际运行 Linux bash 命令，返回 jobId、stdout/stderr 和退出状态；可长时间运行，用 jobs.read 持续查询。不是 Android shell。',
        {
          'projectId': _id,
          'command': _str,
          'cwd': _str,
          'timeoutMs': _num,
          'waitMs': _num,
        },
        ['projectId', 'command'],
        'write',
      ),
      ('jobs.list', '恢复时核对本会话全部进程和历史结果，未知结果不重跑。', {}, [], 'read'),
      (
        'jobs.input',
        '向本会话仍在运行的进程输入文本；end=true 关闭输入。恢复后无真实输入通道时拒绝。',
        {
          'jobId': _id,
          'text': _str,
          'end': {'type': 'boolean'},
        },
        ['jobId', 'text'],
        'write',
      ),
      (
        'files.glob',
        '在当前项目匹配文件路径（*、**、?），不自动交付文件。',
        {'projectId': _id, 'pattern': _str},
        ['projectId', 'pattern'],
        'read',
      ),
      (
        'files.image',
        '读取当前项目真实 PNG/JPEG/WebP（600 KB 内）并交给当前模型；不支持视觉时如实处理，不伪造图像内容。',
        {'projectId': _id, 'path': _str},
        ['projectId', 'path'],
        'read',
      ),
      (
        'jobs.read',
        '读取真实持续输出和退出码；可等待最多 10 秒；运行中不算检查通过。',
        {
          'jobId': _id,
          'stdoutOffset': _num,
          'stderrOffset': _num,
          'waitMs': _num,
        },
        ['jobId'],
        'read',
      ),
      (
        'jobs.stop',
        '停止本会话指定进程组，核对退出；不会停止其他任务。',
        {'jobId': _id},
        ['jobId'],
        'write',
      ),
      (
        'deliver.prepare',
        '只交付用户最终需要的文件：传明确 files[{path,purpose}]；不扫描目录。核对存在、格式、大小、哈希，保留独立版本，再创建文件组卡片。过程脚本/日志/截图默认不交付。',
        {
          'projectId': _id,
          'files': {
            'type': 'array',
            'maxItems': 40,
            'items': _schema(
              {'path': _str, 'purpose': _str},
              ['path', 'purpose'],
            ),
          },
        },
        ['projectId', 'files'],
        'write',
      ),
    ])
      {
        'id': 'coding.${entry.$1}',
        'description': entry.$2,
        'parameters': _schema(entry.$3, entry.$4),
        'effect': entry.$5,
        'available': true,
        'source': '小云内置编程',
      },
  ];
  @override
  Future<List<Map<String, dynamic>>> catalog() async => projectId == null
      ? definitions
      : definitions
            .where(
              (d) => !const {
                'coding.projects.create',
                'coding.projects.list',
                'coding.projects.archive',
                'coding.legacy.sessions',
                'coding.legacy.read',
              }.contains(d['id']),
            )
            .toList();
  @override
  Future<DeviceToolReceipt> invoke(
    String tool,
    Map<String, dynamic> args,
    String requestId,
    void Function() check,
  ) async {
    check();
    final definition = definitions.where((d) => d['id'] == tool).firstOrNull;
    if (definition == null) throw const FormatException('内置编程接口不存在。');
    if (projectId != null && !(await catalog()).contains(definition))
      throw StateError('计划未授权此项目管理操作。');
    validatePluginArguments(args, definition['parameters']);
    if (projectId != null &&
        args['projectId'] != null &&
        args['projectId'] != projectId)
      throw StateError('定时计划只能使用保存时选定的项目。');
    _invokedTasks.add(taskId());
    final raw = await cloudExecutionChannel
        .invokeMapMethod<String, dynamic>('invoke', {
          'tool': tool,
          'arguments': args,
          'owner': owner,
          'taskId': taskId(),
          'requestId': requestId,
        });
    check();
    final data = Map<String, dynamic>.from(raw ?? {});
    final value = data['value'];
    return DeviceToolReceipt({
      ...data,
      'tool': tool,
      'requestId': requestId,
      'summary':
          data['message'] ??
          (data['outcome'] == 'verified' ? '已取得内置环境真实回执。' : '编程操作未完成。'),
      if (tool == 'coding.exec.start' && value is Map)
        'value': {...value, 'businessVerified': value['state'] == 'exited'},
    });
  }

  @override
  Future<Map<String, dynamic>> cancel() async {
    if (!_invokedTasks.contains(taskId())) return {'outcome': 'cancelled'};
    try {
      final raw = await cloudExecutionChannel.invokeMapMethod<String, dynamic>(
        'invoke',
        {
          'tool': 'coding.cancel',
          'arguments': <String, dynamic>{},
          'owner': owner,
          'taskId': taskId(),
          'requestId':
              'cancel_${DateTime.now().microsecondsSinceEpoch}_${++_cancelSerial}',
        },
      );
      return {
        'outcome':
            raw?['outcome'] == 'verified' &&
                (raw?['value'] as Map?)?['stopped'] == true
            ? 'cancelled'
            : 'unknown',
      };
    } catch (_) {
      return {'outcome': 'unknown'};
    }
  }
}

class CombinedAssistantTools implements AssistantExtensions {
  CombinedAssistantTools(this.tools);
  final List<AssistantExtensions> tools;
  @override
  Future<List<Map<String, dynamic>>> catalog() async => [
    for (final tool in tools) ...await tool.catalog(),
  ];
  @override
  Future<DeviceToolReceipt> invoke(
    String tool,
    Map<String, dynamic> args,
    String requestId,
    void Function() check,
  ) async {
    for (final provider in tools) {
      if ((await provider.catalog()).any((d) => d['id'] == tool))
        return provider.invoke(tool, args, requestId, check);
    }
    throw const FormatException('当前执行接口不可用。');
  }

  @override
  Future<Map<String, dynamic>> cancel() async {
    final results = await Future.wait(tools.map((t) => t.cancel()));
    return {
      'outcome': results.every((r) => r['outcome'] == 'cancelled')
          ? 'cancelled'
          : 'unknown',
    };
  }
}

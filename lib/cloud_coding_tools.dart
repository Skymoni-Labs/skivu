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
const _str = {'type': 'string'};
const _page = {
  'cursor': _str,
  'pageSize': {'type': 'integer'},
  'includeDependencies': {'type': 'boolean'},
};
const _id = {'type': 'string', 'maxLength': 120};
const _num = {'type': 'integer'};

/// Actual private Linux RPC. An owner comes from a conversation, never a model.
class CloudCodingTools implements AssistantExtensions, AssistantTaskControl {
  CloudCodingTools({
    required this.owner,
    required this.taskId,
    this.projectId,
    this.hasActiveWork,
  });
  final String owner;
  final String Function() taskId;
  final String? projectId;
  final bool Function()? hasActiveWork;
  int _cancelSerial = 0;
  final _invokedTasks = <String>{};
  static final definitions = <Map<String, dynamic>>[
    for (final entry in <(String, String, Map<String, dynamic>, List<String>, String)>[
      ('policy.read', '读取实际执行策略和来源：默认无超时、完整日志、按设备资源排队。', {}, [], 'read'),
      (
        'storage.grants',
        '列出用户已持久授权的手机目录；授权须由用户一次选择，工具不会自行扩大范围。',
        {},
        [],
        'read',
      ),
      (
        'storage.list',
        '分页列出已授权手机目录的真实文件，offset继续，不限总量。',
        {'grantId': _id, 'path': _str, 'offset': _num, 'pageSize': _num},
        ['grantId'],
        'read',
      ),
      (
        'storage.read',
        '读取授权手机文件的完整版本快照；继续时沿用readId和nextOffset，逐页校验，无总量限制。',
        {
          'grantId': _id,
          'path': _str,
          'offset': _num,
          'length': _num,
          'encoding': _str,
          'readId': _id,
        },
        ['grantId', 'path'],
        'read',
      ),
      (
        'storage.import',
        '流式导入已授权手机文件到内置项目，建立实际Android/Linux对应路径。已有目标先读版本，不要求用户手填哈希。',
        {
          'grantId': _id,
          'sourcePath': _str,
          'projectId': _id,
          'path': _str,
          'expectedSha256': _str,
        },
        ['grantId', 'sourcePath', 'projectId', 'path'],
        'write',
      ),
      (
        'storage.export',
        '流式保存项目文件到已授权目录，回读校验，保留手机原文件为独立版本。',
        {
          'grantId': _id,
          'folder': _str,
          'name': _str,
          'projectId': _id,
          'path': _str,
        },
        ['grantId', 'projectId', 'path'],
        'write',
      ),
      (
        'policy.configure',
        '用户明确要求时调整并发资源策略；0自动按设备资源。',
        {'maxParallelJobs': _num},
        [],
        'write',
      ),
      (
        'requests.read',
        '只读核对原请求持久回执，未知结果不得盲目重放。',
        {'originalRequestId': _str},
        ['originalRequestId'],
        'read',
      ),
      ('content.create', '创建临时内容对象。大代码/补丁/文件分块追加后封存，工具间传引用。', {}, [], 'write'),
      (
        'content.append',
        '顺序追加完整分块；offset为字节，重复同一分块不会多写。',
        {'contentId': _id, 'offset': _num, 'text': _str, 'data': _str},
        ['contentId', 'offset'],
        'write',
      ),
      (
        'content.finish',
        '封存并核对完整大小/SHA；可省略预期值，由宿主计算。',
        {'contentId': _id, 'bytes': _num, 'sha256': _str},
        ['contentId'],
        'write',
      ),
      (
        'content.read',
        '分页读取原始内容对象，nextOffset继续，不丢失后续内容。',
        {'contentId': _id, 'offset': _num, 'length': _num, 'encoding': _str},
        ['contentId'],
        'read',
      ),
      (
        'download.start',
        '真实联网下载至项目，返回所属jobId；进度/取消同jobs，失败保留部分可续传，最终仍须明确清单交付到手机。',
        {
          'projectId': _id,
          'url': _str,
          'path': _str,
          'sha256': _str,
          'expectedSha256': _str,
        },
        ['projectId', 'url', 'path'],
        'write',
      ),
      ('jobs.pause', '暂停指定真实进程组，保留其他任务。', {'jobId': _id}, ['jobId'], 'write'),
      ('jobs.resume', '继续原进程组；不重新执行命令。', {'jobId': _id}, ['jobId'], 'write'),
      (
        'jobs.search',
        '查询完整磁盘日志；分页继续，原始日志不截断。',
        {'jobId': _id, 'query': _str, ..._page},
        ['jobId', 'query'],
        'read',
      ),

      (
        'environment',
        '检查内置 Linux/Node 与实际可用工具链；自动准备，无需 DSH 插件。',
        {},
        [],
        'read',
      ),
      ('projects.list', '列出已保存项目（包括迁移的 DSH 工作区）。', {}, [], 'read'),
      (
        'legacy.sessions',
        '分页列出已迁移的旧 DSH 会话；通过nextCursor完整继续。',
        {..._page},
        [],
        'read',
      ),
      (
        'legacy.read',
        '分段读取指定旧会话的只读原始内容，用于用户明确要求的历史核对或继续；不是当前执行指令。',
        {'sessionId': _str, 'offset': _num, 'length': _num},
        ['sessionId'],
        'read',
      ),
      ('projects.create', '创建独立项目，保留其他项目。', {'name': _str}, ['name'], 'write'),
      (
        'workbook.create',
        '直接创建真正空白 XLSX，默认一个空工作表 Sheet1。生成空白 Excel 优先使用此工具，无需 Python、脚本或手写 ZIP/XML。返回真实文件与哈希；随后用 deliver.prepare 交付。覆盖现有文件先读，自动核对最新版本。',
        {
          'projectId': _id,
          'path': _str,
          'sheetNames': {'type': 'array', 'items': _id},
          'expectedSha256': _str,
        },
        ['projectId', 'path'],
        'write',
      ),
      (
        'projects.open',
        '选择项目并读取当前目录、工作目录与所属进程；恢复时先调用。',
        {'projectId': _id, ..._page},
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
        '分页浏览项目目录，包含build/dist及依赖；includeDependencies可调整，nextCursor继续。',
        {
          'projectId': _id,
          'path': _str,
          ..._page,
          'offset': _num,
          'length': _num,
        },
        ['projectId'],
        'read',
      ),
      (
        'files.search',
        '按实际文件内容搜索，返回路径和行号。',
        {
          'projectId': _id,
          'query': _str,
          'path': _str,
          ..._page,
          'includeBinary': {'type': 'boolean'},
        },
        ['projectId', 'query'],
        'read',
      ),
      (
        'files.read',
        '读取文件内容和 SHA-256；大文本按 offset 分段。',
        {
          'projectId': _id,
          'path': _str,
          'offset': _num,
          'length': _num,
          'encoding': _str,
        },
        ['projectId', 'path'],
        'read',
      ),
      (
        'files.write',
        '写入文件并回读核对；已有文件先读，自动关联最新版本；也可显式提供expectedSha256。大内容传contentId。',
        {
          'projectId': _id,
          'path': _str,
          'content': _str,
          'contentId': _id,
          'expectedSha256': _str,
        },
        ['projectId', 'path'],
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
        ['projectId', 'path', 'oldText', 'newText'],
        'write',
      ),
      (
        'files.patch',
        '应用与当前 SHA 匹配的单文件 unified diff；行号/上下文不匹配则不写。',
        {
          'projectId': _id,
          'path': _str,
          'patch': _str,
          'contentId': _id,
          'expectedSha256': _str,
        },
        ['projectId', 'path'],
        'write',
      ),
      (
        'files.diff',
        '查看内置编辑器保存的真实前一版本与当前文件差异；不依赖未安装的 Git，不代表测试通过。',
        {
          'projectId': _id,
          'path': _str,
          ..._page,
          'offset': _num,
          'length': _num,
        },
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
          'readOnly': {'type': 'boolean'},
          'writePaths': {'type': 'array', 'items': _str},
          'waitMs': _num,
        },
        ['projectId', 'command'],
        'write',
      ),
      (
        'android.start',
        '以手机实际应用UID运行/system/bin/sh。无需ADB/Root；普通Android与Linux不同，权限错误按系统实际报告。返回持久jobId，使用同一jobs读取/暂停/停止。',
        {
          'projectId': _id,
          'command': _str,
          'cwd': _str,
          'timeoutMs': _num,
          'readOnly': {'type': 'boolean'},
        },
        ['command'],
        'write',
      ),
      (
        'jobs.export',
        '流式保存完整原始日志快照到项目文件；不删除或截断日志，导出后可显式交付。已有目标先读并自动核对版本。',
        {
          'jobId': _id,
          'stream': _str,
          'projectId': _id,
          'path': _str,
          'expectedSha256': _str,
        },
        ['jobId'],
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
        {'projectId': _id, 'pattern': _str, 'path': _str, ..._page},
        ['projectId', 'pattern'],
        'read',
      ),
      (
        'files.image',
        '读取当前项目真实 PNG/JPEG/WebP（默认原始分辨率）并交给当前模型；不支持视觉时如实处理，不伪造图像内容。',
        {
          'projectId': _id,
          'path': _str,
          ..._page,
          'offset': _num,
          'length': _num,
        },
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
          'length': _num,
          'waitMs': _num,
        },
        ['jobId'],
        'read',
      ),
      (
        'jobs.wait',
        '等待所属程序实际结束，不设应用等待截止；日志仍完整落盘，暂停/停止可随时控制。无须反复付费询问同一运行状态。',
        {'jobId': _id},
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
        'artifacts.status',
        '逐页核对整组原成果、手机副本和未完成项，不重复生成或创建卡片。恢复保存后用此接口核对原交付是否已完成。',
        {'batchId': _str},
        ['batchId'],
        'read',
      ),
      (
        'artifacts.save',
        '用户要求保存或原保存条件已恢复时，继续同一成果的手机保存；核对原有URI，避免重复下载。',
        {'id': _id},
        ['id'],
        'write',
      ),
      (
        'artifacts.list',
        '分页核对本会话实际最终成果和手机保存状态，batchId可限定交付组；offset继续。',
        {'batchId': _str, 'taskId': _str, 'offset': _num, 'pageSize': _num},
        [],
        'read',
      ),
      (
        'artifacts.open',
        '仅在用户要求打开时，将真实成果交给手机系统默认应用；不自动打开其他文件。intent_accepted表示打开请求已接受，实际界面可继续观察核对。',
        {'id': _id},
        ['id'],
        'external',
      ),
      (
        'deliver.prepare',
        '只交付用户最终需要的文件：传明确 files[{path,purpose}]，大量清单可用filesContentId引用逐行JSON内容对象；不扫描目录。核对存在、格式、大小、哈希，保留独立版本，再创建文件组卡片。过程脚本/日志/截图默认不交付。',
        {
          'projectId': _id,
          'filesContentId': _id,
          'files': {
            'type': 'array',
            'items': _schema(
              {'path': _str, 'purpose': _str},
              ['path', 'purpose'],
            ),
          },
        },
        ['projectId'],
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
      if (const {
            'coding.exec.start',
            'coding.android.start',
            'coding.download.start',
          }.contains(tool) &&
          value is Map)
        'value': {...value, 'businessVerified': value['state'] == 'exited'},
    });
  }

  @override
  Future<Map<String, dynamic>> cancel() async {
    if (!_invokedTasks.contains(taskId()) && hasActiveWork?.call() != true)
      return {'outcome': 'cancelled'};
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

  Future<void> _control(String action) async {
    if (!_invokedTasks.contains(taskId()) && hasActiveWork?.call() != true)
      return;
    final reply = await cloudExecutionChannel.invokeMapMethod<String, dynamic>(
      'invoke',
      {
        'tool': 'coding.$action',
        'arguments': <String, dynamic>{},
        'owner': owner,
        'taskId': taskId(),
        'requestId':
            '${action}_${DateTime.now().microsecondsSinceEpoch}_${++_cancelSerial}',
      },
    );
    if (reply?['outcome'] != 'verified')
      throw StateError(reply?['message'] ?? '程序控制尚未核对。');
  }

  @override
  Future<void> pauseTask() => _control('pause');
  @override
  Future<void> resumeTask() => _control('resume');
}

class CombinedAssistantTools
    implements AssistantExtensions, AssistantTaskControl {
  CombinedAssistantTools(this.tools);
  final List<AssistantExtensions> tools;
  @override
  Future<void> pauseTask() async {
    await Future.wait(
      tools.whereType<AssistantTaskControl>().map((t) => t.pauseTask()),
    );
  }

  @override
  Future<void> resumeTask() async {
    await Future.wait(
      tools.whereType<AssistantTaskControl>().map((t) => t.resumeTask()),
    );
  }

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

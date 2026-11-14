import 'open_plugin_tools.dart';
import 'phone_flow_schema.dart';

/// Versioned host capabilities shared by the main assistant, plugins and DSH.
/// A catalog entry describes an operation; actual permission and result evidence
/// are always supplied by the native backend, never inferred from this list.
class DeviceToolDefinition {
  const DeviceToolDefinition({
    required this.id,
    required this.description,
    required this.permission,
    required this.parameters,
    this.effect = 'read',
    this.additionalPermissions = const [],
  });

  final String id, description, permission, effect;
  final List<String> additionalPermissions;
  final Map<String, dynamic> parameters;

  void validate(Map<String, dynamic> arguments) {
    validatePluginArguments(arguments, parameters);
    if (id == 'ui.flow') validatePhoneFlowSemantics(arguments);
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'description': description,
    'permission': permission,
    if (additionalPermissions.isNotEmpty)
      'requiredPermissions': [permission, ...additionalPermissions],
    'effect': effect,
    'parameters': parameters,
  };
}

Map<String, dynamic> _object(
  Map<String, dynamic> properties, [
  List<String> required = const [],
]) => {
  'type': 'object',
  'properties': properties,
  'required': required,
  'additionalProperties': false,
};

Map<String, dynamic> _text(int max, [String? description]) => {
  'type': 'string',
  if (description != null) 'description': description,
};

final builtinDeviceTools = <DeviceToolDefinition>[
  DeviceToolDefinition(
    id: 'ui.flow',
    description: '在授权软件内本地连续定位、操作、条件等待与核验；每步有真实证据和持久检查点，执行期间不调用模型。',
    permission: 'device.control',
    additionalPermissions: ['device.observe'],
    effect: 'external',
    parameters: phoneFlowParameters,
  ),
  DeviceToolDefinition(
    id: 'ui.flow.read',
    description: '只读查询本任务原本地流程的每步状态、停止原因和耗时，不重放动作。',
    permission: 'device.observe',
    parameters: phoneFlowReferenceParameters,
  ),
  DeviceToolDefinition(
    id: 'ui.flow.resume',
    description: '明确继续本任务原流程；跳过已核验步骤，未知动作仅重新核验，不能重放；保留原权限范围。',
    permission: 'device.control',
    additionalPermissions: ['device.observe'],
    effect: 'external',
    parameters: phoneFlowReferenceParameters,
  ),
  DeviceToolDefinition(
    id: 'device.receipt',
    description: '只读核对本任务原请求的持久回执，不重放动作；派发与业务完成分开。',
    permission: 'device.observe',
    parameters: _object(
      {'originalRequestId': _text(120)},
      ['originalRequestId'],
    ),
  ),
  DeviceToolDefinition(
    id: 'device.status',
    description: '读取实际授权、原生服务和 shell 后端状态；不申请或扩大权限。',
    permission: 'device.observe',
    parameters: _object({}),
  ),
  DeviceToolDefinition(
    id: 'apps.list',
    description: '列出设备上允许启动的软件及其包名。',
    permission: 'device.observe',
    parameters: _object({}),
  ),
  DeviceToolDefinition(
    id: 'apps.launch',
    description: '打开获准的软件；启动回执不表示软件内的任务已完成。',
    permission: 'device.control',
    effect: 'external',
    parameters: _object({'package': _text(200)}, ['package']),
  ),
  DeviceToolDefinition(
    id: 'ui.observe',
    description:
        '观察授权软件的真实控件和本地OCR文字位置，返回本轮 observationId 与目标ID。可选视觉优先；识别文字不代表控件可点击、可编辑或已选中。',
    permission: 'device.observe',
    parameters: _object({
      'observationId': _text(100),
      'offset': {'type': 'integer'},
      'pageSize': {'type': 'integer'},
      'query': _text(1000),
      'recognitionMode': {
        'type': 'string',
        'enum': ['auto', 'visual', 'controls'],
      },
      'region': {
        'type': 'array',
        'minItems': 4,
        'maxItems': 4,
        'items': {'type': 'number', 'minimum': 0, 'maximum': 1},
      },
    }),
  ),
  DeviceToolDefinition(
    id: 'ui.wait',
    description: '等待 100–10000 毫秒后重新观察实际界面，可取消，不使用旧节点。',
    permission: 'device.observe',
    parameters: _object(
      {
        'milliseconds': {'type': 'integer'},
      },
      ['milliseconds'],
    ),
  ),
  DeviceToolDefinition(
    id: 'ui.verify',
    description:
        '用新的实际观察核对原动作 requestId；expect.kind 为 text/checked/selected/navigation，传明确 text、checked 或 selected，可指定 package/viewId。条件必须证明实际变化；不满足则保留未知，不重复动作。',
    permission: 'device.observe',
    parameters: _object(
      {
        'requestId': _text(120),
        'expect': _object(
          {
            'kind': {
              'type': 'string',
              'enum': ['text', 'checked', 'selected', 'navigation'],
            },
            'package': _text(200),
            'viewId': _text(300),
            'description': _text(300),
            'text': _text(12000),
            'checked': {'type': 'boolean'},
            'selected': {'type': 'boolean'},
          },
          ['kind'],
        ),
      },
      ['requestId', 'expect'],
    ),
  ),
  DeviceToolDefinition(
    id: 'ui.screenshot',
    description:
        '获取当前授权可见页面的真实截图，临时排除浮岛；仅在节点不足且确需图像时使用。图片直接传当前模型，模型不支持视觉或安全窗口截图被拒绝时如实等待，不猜内容。',
    permission: 'device.observe',
    parameters: _object({
      'maxWidth': {'type': 'integer'},
      'format': {
        'type': 'string',
        'enum': ['png', 'jpeg'],
      },
      'quality': {'type': 'integer'},
      'crop': {
        'type': 'array',
        'maxItems': 4,
        'items': {'type': 'integer'},
      },
    }),
  ),
  DeviceToolDefinition(
    id: 'ui.longPress',
    description: '长按最新观察中的真实控件；之后重新观察和核对。',
    permission: 'device.control',
    effect: 'external',
    parameters: _object(
      {'observationId': _text(100), 'elementId': _text(100)},
      ['observationId', 'elementId'],
    ),
  ),
  DeviceToolDefinition(
    id: 'ui.swipe',
    description: '在最新观察的控件范围内向 up/down/left/right 滑动；不用旧坐标盲点。',
    permission: 'device.control',
    effect: 'external',
    parameters: _object(
      {
        'observationId': _text(100),
        'elementId': _text(100),
        'direction': {
          'type': 'string',
          'enum': ['up', 'down', 'left', 'right'],
        },
      },
      ['observationId', 'elementId', 'direction'],
    ),
  ),
  DeviceToolDefinition(
    id: 'ui.tap',
    description: '点击本轮观察中存在的控件；界面变化后必须重新观察。',
    permission: 'device.control',
    effect: 'external',
    parameters: _object(
      {'observationId': _text(100), 'elementId': _text(100)},
      ['observationId', 'elementId'],
    ),
  ),
  DeviceToolDefinition(
    id: 'ui.input',
    description: '在当前观察中的可编辑控件输入文字；不读取或处理密码字段。',
    permission: 'device.control',
    effect: 'external',
    parameters: _object(
      {
        'observationId': _text(100),
        'elementId': _text(100),
        'text': _text(12000),
      },
      ['observationId', 'elementId', 'text'],
    ),
  ),
  DeviceToolDefinition(
    id: 'ui.scroll',
    description: '滚动当前观察中的控件；操作后重新观察实际结果。',
    permission: 'device.control',
    effect: 'external',
    parameters: _object(
      {
        'observationId': _text(100),
        'elementId': _text(100),
        'direction': {
          'type': 'string',
          'enum': ['forward', 'backward'],
        },
      },
      ['observationId', 'elementId', 'direction'],
    ),
  ),
  DeviceToolDefinition(
    id: 'ui.back',
    description: '执行系统返回动作。',
    permission: 'device.control',
    effect: 'external',
    parameters: _object({}),
  ),
  DeviceToolDefinition(
    id: 'ui.home',
    description: '返回系统桌面。',
    permission: 'device.control',
    effect: 'external',
    parameters: _object({}),
  ),
  DeviceToolDefinition(
    id: 'clock.alarm.create',
    description:
        '通过 Android AlarmClock 接口设置手机时钟闹钟。hour 为 0–23，minute 为 0–59；days 为 Calendar 星期编号 1–7。接口派发后需核对时钟结果，不将派发当成功。',
    permission: 'device.system',
    effect: 'external',
    parameters: _object(
      {
        'hour': {'type': 'integer'},
        'minute': {'type': 'integer'},
        'label': _text(160),
        'days': {
          'type': 'array',
          'items': {
            'type': 'integer',
            'enum': [1, 2, 3, 4, 5, 6, 7],
          },
          'maxItems': 7,
        },
        'vibrate': {'type': 'boolean'},
      },
      ['hour', 'minute'],
    ),
  ),
  DeviceToolDefinition(
    id: 'clock.timer.start',
    description: '通过手机时钟启动倒计时，seconds 为正整数；结果需要核对。',
    permission: 'device.system',
    effect: 'external',
    parameters: _object(
      {
        'seconds': {'type': 'integer'},
        'label': _text(160),
      },
      ['seconds'],
    ),
  ),
  DeviceToolDefinition(
    id: 'clock.alarms.show',
    description: '打开手机时钟的闹钟列表以检查设置结果。',
    permission: 'device.system',
    effect: 'external',
    parameters: _object({}),
  ),
  DeviceToolDefinition(
    id: 'settings.open',
    description: '打开明确的系统设置页面；打开页面不表示设置已更改或授权完成。',
    permission: 'device.system',
    effect: 'external',
    parameters: _object(
      {
        'page': {
          'type': 'string',
          'enum': [
            'settings',
            'wifi',
            'bluetooth',
            'display',
            'sound',
            'accessibility',
            'application',
          ],
        },
      },
      ['page'],
    ),
  ),
  DeviceToolDefinition(
    id: 'settings.brightness.read',
    description: '读取当前系统亮度和自动亮度模式。',
    permission: 'device.observe',
    parameters: _object({}),
  ),
  DeviceToolDefinition(
    id: 'settings.brightness.write',
    description: '在真实 WRITE_SETTINGS 授权存在时调整系统亮度，level 为 0–255；读取系统值核对结果。',
    permission: 'device.system',
    effect: 'external',
    parameters: _object(
      {
        'level': {'type': 'integer'},
      },
      ['level'],
    ),
  ),
  DeviceToolDefinition(
    id: 'shell.execute',
    description:
        '在单独授权的 Android /system/bin/sh 后端执行代码，返回实际 uid、退出码和输出。等待后台子进程须在同一调用内 wait；无后端或未授权时不得用普通 app 进程假装成功。',
    permission: 'device.shell',
    effect: 'external',
    parameters: _object(
      {
        'command': _text(12000),
        'timeoutSeconds': {
          'type': 'integer',
          'minimum': 0,
          'description':
              '用户指定的执行时长，单位秒；0 或省略不设置应用超时。完整输出落盘，用 shell.output.read 分页读取。',
        },
      },
      ['command'],
    ),
  ),
  DeviceToolDefinition(
    id: 'shell.output.read',
    description: '只读原高权限执行的完整磁盘日志，按字节继续读取；不会重新执行命令。',
    permission: 'device.observe',
    parameters: _object(
      {
        'outputId': _text(100),
        'stream': {
          'type': 'string',
          'enum': ['stdout', 'stderr'],
        },
        'offset': {'type': 'integer', 'minimum': 0},
        'length': {'type': 'integer', 'minimum': 1},
      },
      ['outputId'],
    ),
  ),
  DeviceToolDefinition(
    id: 'shell.output.export',
    description:
        '封存原高权限日志的完整字节快照为内容引用，用 coding.files.write(contentId) 写文件并按需交付。',
    permission: 'device.observe',
    parameters: _object(
      {
        'outputId': _text(100),
        'stream': {
          'type': 'string',
          'enum': ['stdout', 'stderr'],
        },
      },
      ['outputId'],
    ),
  ),
];

/// Installed from the pinned native dsh-go catalog, with its original schemas.
/// Legacy definitions remain available to inspect saved receipts, not to execute.
final dshGoDeviceTools = <String, DeviceToolDefinition>{};

DeviceToolDefinition deviceTool(String id) =>
    dshGoDeviceTools[id] ??
    builtinDeviceTools.firstWhere(
      (tool) => tool.id == id,
      orElse: () => throw const FormatException('设备工具不存在。'),
    );

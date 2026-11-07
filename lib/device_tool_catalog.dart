import 'open_plugin_tools.dart';

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
  });

  final String id, description, permission, effect;
  final Map<String, dynamic> parameters;

  void validate(Map<String, dynamic> arguments) =>
      validatePluginArguments(arguments, parameters);

  Map<String, dynamic> toJson() => {
    'id': id,
    'description': description,
    'permission': permission,
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
  'maxLength': max,
  if (description != null) 'description': description,
};

final builtinDeviceTools = <DeviceToolDefinition>[
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
    description: '观察当前获准软件的真实控件，返回本轮 observationId 和控件 ID。',
    permission: 'device.observe',
    parameters: _object({}),
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
          'description': '执行超时，1 至 600 秒；省略时为 30 秒。',
        },
      },
      ['command'],
    ),
  ),
];

DeviceToolDefinition deviceTool(String id) => builtinDeviceTools.firstWhere(
  (tool) => tool.id == id,
  orElse: () => throw const FormatException('设备工具不存在。'),
);

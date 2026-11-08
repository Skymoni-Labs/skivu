import 'dart:async';
import 'package:flutter/services.dart';
import 'device_tool_catalog.dart';

/// A request result explicitly distinguishes dispatch from verified completion.
class DeviceToolReceipt {
  DeviceToolReceipt(Map<String, dynamic> value)
    : data = Map.unmodifiable(value) {
    if (data['requestId'] is! String ||
        !const {
          'verified',
          'dispatched',
          'permission_required',
          'failed',
          'unknown',
          'cancelled',
        }.contains(data['outcome'])) {
      throw const FormatException('设备执行回执格式无效。');
    }
  }
  final Map<String, dynamic> data;
  String get outcome => data['outcome'] as String;
  bool get verified => outcome == 'verified';
  bool get needsPermission => outcome == 'permission_required';
  String get summary => data['summary'] as String? ?? '';
}

typedef DeviceEngineTransport =
    Future<Map<String, dynamic>> Function(
      String method,
      Map<String, dynamic> arguments,
    );

class DeviceEngine {
  DeviceEngine({DeviceEngineTransport? transport})
    : _transport = transport ?? _native;
  static const channel = MethodChannel('skivu/device_engine');
  static int _serial = 0;
  final DeviceEngineTransport _transport;

  static Future<Map<String, dynamic>> _native(
    String method,
    Map<String, dynamic> arguments,
  ) async {
    final value = await channel.invokeMapMethod<String, dynamic>(
      method,
      arguments,
    );
    if (value == null) throw const FormatException('设备没有返回执行回执。');
    return Map<String, dynamic>.from(value);
  }

  Future<Map<String, dynamic>> status() => _transport('status', {});
  Future<List<Map<String, dynamic>>> alarms() async {
    final values = await channel.invokeListMethod<dynamic>('alarms.list') ?? [];
    return values.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<Map<String, dynamic>> cancelAlarm(String id) =>
      _transport('alarms.cancel', {'id': id});
  Future<Map<String, dynamic>> previousEffect(
    String tool,
    Map<String, dynamic> arguments,
  ) {
    if (tool.startsWith('plugin:')) return Future.value({'found': false});
    deviceTool(tool).validate(arguments);
    return _transport('effect.lookup', {'tool': tool, 'arguments': arguments});
  }

  Future<void> beginTask(String taskId) async {
    await _transport('session.start', {'taskId': taskId});
  }

  Future<void> endTask(String taskId) async {
    await _transport('session.end', {'taskId': taskId});
  }

  Future<List<Map<String, dynamic>>> installedApps() async {
    final values = await channel.invokeListMethod<dynamic>('apps') ?? [];
    return values.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<Map<String, dynamic>> pair(int port, String code) =>
      _transport('adb.pair', {'port': port, 'code': code});
  Future<Map<String, dynamic>> startPairingNotification() =>
      _transport('pairing.start', {});
  Future<Map<String, dynamic>> connect(int port, {bool trustPeer = false}) =>
      _transport('adb.connect', {'port': port, 'trustPeer': trustPeer});
  Future<Map<String, dynamic>> disconnect() => _transport('adb.stop', {});
  Future<Map<String, dynamic>> stop() => _transport('stop', {});
  Future<Map<String, dynamic>> cancelRequest(String owner, String requestId) =>
      _transport('cancelRequest', {'owner': owner, 'requestId': requestId});
  Future<Map<String, dynamic>> configure({
    required bool enabled,
    required bool system,
    required bool control,
    required bool shell,
    required List<String> packages,
  }) => _transport('configure', {
    'enabled': enabled,
    'system': system,
    'control': control,
    'shell': shell,
    'packages': packages,
  });

  Future<Map<String, dynamic>> openAuthorization(String page) =>
      _transport('authorization', {'page': page});

  Future<List<Map<String, dynamic>>> catalog() async {
    final state = await status();
    return [
      for (final tool in [...builtinDeviceTools, ...nativeBackgroundTools])
        {
          ...tool.toJson(),
          'available': switch (tool.permission) {
            'device.observe' =>
              tool.id == 'device.status' ||
                  state['enabled'] == true &&
                      (tool.id != 'ui.observe' ||
                          state['accessibility'] == true),
            'device.control' =>
              state['enabled'] == true &&
                  state['control'] == true &&
                  (!tool.id.startsWith('ui.') ||
                      state['accessibility'] == true),
            'device.system' =>
              state['enabled'] == true && state['system'] == true,
            'device.shell' =>
              state['enabled'] == true &&
                  state['shell'] == true &&
                  state['shellConnected'] == true,
            _ => false,
          },
        },
    ];
  }

  /// owner is supplied by the trusted host, not plugin/DSH request parameters.
  /// The same id must be reused when querying an uncertain write.
  Future<DeviceToolReceipt> invoke(
    String toolId,
    Map<String, dynamic> arguments, {
    required String owner,
    String? requestId,
    bool backgroundOnly = true,
  }) async {
    final definition = deviceTool(toolId);
    definition.validate(arguments);
    if (!RegExp(r'^[a-zA-Z0-9_.:-]{1,180}$').hasMatch(owner)) {
      throw const FormatException('设备调用身份无效。');
    }
    final id =
        requestId ?? '${DateTime.now().microsecondsSinceEpoch}_${++_serial}';
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,100}$').hasMatch(id)) {
      throw const FormatException('设备请求编号无效。');
    }
    final raw = await _transport('invoke', {
      'version': 1,
      'owner': owner,
      'requestId': id,
      'tool': toolId,
      'arguments': arguments,
      'executionPolicy': backgroundOnly ? 'background' : 'interactive',
    });
    if (raw['requestId'] != id) {
      throw const FormatException('设备回执与本次请求不匹配。');
    }
    return DeviceToolReceipt(raw);
  }
}

final deviceEngine = DeviceEngine();

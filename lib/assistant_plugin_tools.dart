import 'assistant_engine.dart';
import 'package:flutter/services.dart';
import 'device_engine.dart';
import 'device_engine_plugin.dart';
import 'open_plugin.dart';
import 'open_plugin_network.dart';
import 'open_plugin_runtime.dart';
import 'open_plugin_tools.dart';

/// Manifest registration is separate from role-companion bindings.
class AssistantPluginTools implements AssistantExtensions {
  AssistantPluginTools(this.registry, {this.engine}) {
    registry.addListener(_changed);
  }
  final OpenPluginRegistry registry;
  final DeviceEngine? engine;
  final active = <OpenPluginRuntime, OpenPluginRecord>{};
  final activeScopes = <OpenPluginRuntime, DeviceEngineScope>{};
  void dispose() {
    registry.removeListener(_changed);
    cancel();
  }

  void _changed() {
    for (final entry in active.entries.toList()) {
      if (registry.records[entry.value.manifest.id] != entry.value ||
          !entry.value.authorized)
        entry.key.cancel();
    }
  }

  @override
  Future<Map<String, dynamic>> cancel() async {
    final scopes = activeScopes.values.toList();
    for (final runtime in active.keys.toList()) {
      runtime.cancel();
    }
    final results = await Future.wait([
      for (final scope in scopes) scope.closeAndWait(),
    ]);
    return {
      'outcome': results.expand((r) => r).any((r) => r['outcome'] == 'unknown')
          ? 'unknown'
          : 'cancelled',
    };
  }

  Iterable<OpenPluginRecord> get records => registry.records.values.where(
    (r) =>
        r.authorized &&
        r.manifest.permissions.contains('assistant.tools') &&
        r.manifest.assistantTools != null,
  );
  @override
  Future<List<Map<String, dynamic>>> catalog() async => [
    for (final record in records)
      for (final tool in record.manifest.assistantTools!['tools'] as List)
        {
          ...Map<String, dynamic>.from(tool as Map),
          'id': 'plugin:${record.manifest.id}/${tool['id']}',
          'source': record.manifest.name,
          'available': true,
        },
  ];
  @override
  Future<DeviceToolReceipt> invoke(
    String name,
    Map<String, dynamic> args,
    String requestId,
    void Function() check,
  ) async {
    final parts = name.substring('plugin:'.length).split('/');
    if (parts.length != 2) throw const FormatException('插件工具名称无效。');
    final record = records.where((r) => r.manifest.id == parts[0]).firstOrNull;
    if (record == null) throw const PluginApiError('CLOSED', '插件工具未启用或授权已变化。');
    final tool = (record.manifest.assistantTools!['tools'] as List)
        .cast<Map>()
        .where((t) => t['id'] == parts[1])
        .firstOrNull;
    if (tool == null) throw const PluginApiError('NOT_FOUND', '插件没有声明此工具。');
    validatePluginArguments(args, tool['parameters'] as Map);
    void guard() {
      check();
      if (registry.records[record.manifest.id] != record ||
          !record.authorized) {
        throw const PluginApiError('CLOSED', '插件已撤销。');
      }
    }

    late final OpenPluginRuntime runtime;
    final scope = DeviceEngineScope(engine: engine);
    runtime = OpenPluginRuntime(
      registry: registry,
      record: record,
      assistant: true,
      onCancel: scope.close,
      context: {'scope': 'assistant', 'callId': requestId},
      effect: tool['effect'] as String,
      checkContext: guard,
      host: (method, params) => method == 'ui.openExternal'
          ? const MethodChannel(
              'skivu/open_plugin_external',
            ).invokeMethod('open', params)
          : scope.call(
              registry,
              record,
              method,
              params,
              checkRuntime: () {
                guard();
                runtime.check();
              },
            ),
    );
    active[runtime] = record;
    activeScopes[runtime] = scope;
    try {
      final result = await runtime.run(parts[1], args);
      guard();
      return DeviceToolReceipt({
        'requestId': requestId,
        'tool': name,
        'outcome': tool['effect'] == 'read' ? 'verified' : 'dispatched',
        'summary': '插件工具已返回；业务结果以插件数据及实际软件为准。',
        'value': {
          'source': 'plugin',
          'businessVerified': false,
          'result': result,
        },
      });
    } finally {
      active.remove(runtime);
      activeScopes.remove(runtime);
    }
  }
}

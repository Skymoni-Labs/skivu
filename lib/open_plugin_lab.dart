import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'cloud_coding_tools.dart';
import 'open_plugin.dart';
import 'open_plugin_network.dart';

int _labSerial = 0;

/// A data-only API over the existing embedded 小云 runtime. No shell command,
/// host path, model key or DSH application is passed to the plugin.
Future<Object?> invokePluginLab(
  OpenPluginRecord record,
  Map<String, dynamic> params, {
  bool assistant = false,
  bool readOnly = false,
  String? callId,
}) async {
  if (!record.authorized ||
      !record.manifest.permissions.contains('cloud.lab')) {
    throw const PluginApiError('PERMISSION_DENIED', '插件资料库授权已关闭。');
  }
  final request = params['request'];
  if (request is! Map || request['op'] is! String) {
    throw const PluginApiError('INVALID_ARGUMENT', '缺少明确的资料库操作。');
  }
  final key = callId == null
      ? '${DateTime.now().microsecondsSinceEpoch}_${++_labSerial}'
      : '$callId:${jsonEncode(request)}';
  final receipt = await cloudExecutionChannel.invokeMapMethod<String, dynamic>(
    'invoke',
    {
      'tool': 'coding.lab',
      'owner': 'plugin:${record.manifest.id}',
      'taskId': 'plugin_lab',
      'requestId': 'lab_${sha256.convert(utf8.encode(key))}',
      'arguments': {
        'request': Map<String, dynamic>.from(request),
        'assistant': assistant,
        'readOnly': readOnly,
      },
    },
  );
  if (receipt?['outcome'] != 'verified') {
    throw PluginApiError(
      receipt?['outcome'] == 'unknown' ? 'UNKNOWN' : 'LAB_FAILED',
      receipt?['message']?.toString() ?? '操作未完成，请先查询原状态。',
    );
  }
  return receipt?['value'];
}

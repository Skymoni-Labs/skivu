import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'device_tool_catalog.dart';

/// A durable fence for a real-world tool effect, independent of chat editing.
/// It stores no tool arguments, only a normalized operation hash and receipt IDs.
class ToolSubmission {
  ToolSubmission({
    required this.fingerprint,
    required this.taskId,
    required this.requestId,
    required this.outcome,
    required this.tool,
  });
  final String fingerprint, taskId, requestId, tool;
  String outcome;
  bool get protected => const {
    'prepared',
    'dispatched',
    'verified',
    'unknown',
    'user_confirmed',
  }.contains(outcome);
  Map<String, String> toJson() => {
    'fingerprint': fingerprint,
    'taskId': taskId,
    'requestId': requestId,
    'outcome': outcome,
    'tool': tool,
  };
  static List<ToolSubmission> parseList(dynamic raw) => [
    if (raw is List)
      for (final item in raw)
        if (item is Map &&
            [
              'fingerprint',
              'taskId',
              'requestId',
              'outcome',
            ].every((key) => item[key] is String) &&
            (item['tool'] == null || item['tool'] is String) &&
            RegExp(r'^[a-f0-9]{64}$').hasMatch(item['fingerprint']))
          ToolSubmission(
            fingerprint: item['fingerprint'],
            taskId: item['taskId'],
            requestId: item['requestId'],
            outcome: item['outcome'],
            tool: item['tool'] as String? ?? 'clock.alarm.create',
          ),
  ];

  static String? fingerprintFor(
    String tool,
    Map<String, dynamic> args, {
    String? effect,
  }) {
    // Navigation may be needed several times to inspect an effect. It does not
    // create a second business object and must remain usable for verification.
    if (const {
      'apps.launch',
      'settings.open',
      'clock.alarms.show',
      'ui.back',
      'ui.home',
      'ui.scroll',
    }.contains(tool))
      return null;
    if (effect == null && !tool.startsWith('plugin:')) {
      try {
        effect = deviceTool(tool).effect;
      } catch (_) {
        return null;
      }
    }
    if (effect == 'read') return null;
    if (tool != 'clock.alarm.create') {
      return sha256
          .convert(utf8.encode(jsonEncode([tool, _canonical(args)])))
          .toString();
    }
    final hour = args['hour'], minute = args['minute'];
    final days = args['days'] ?? <int>[];
    if (hour is! int ||
        minute is! int ||
        hour < 0 ||
        hour > 23 ||
        minute < 0 ||
        minute > 59 ||
        days is! List ||
        days.any((v) => v is! int || v < 1 || v > 7))
      return null;
    final normalized = days.cast<int>().toSet().toList()..sort();
    // Label/vibration changes must not silently create another alarm at the
    // same time. The user can explicitly approve a repeated submission.
    return sha256
        .convert(utf8.encode(jsonEncode([hour, minute, normalized])))
        .toString();
  }

  static dynamic _canonical(dynamic value) {
    if (value is Map) {
      final keys = value.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: _canonical(value[key])};
    }
    if (value is List) return value.map(_canonical).toList();
    return value;
  }
}

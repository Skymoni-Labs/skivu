// SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Host-private receipts. Plugin storage APIs cannot overwrite these records.
class DeviceTaskJournal {
  static const key = 'skivu.device-task.receipts.v1';
  static const terminal = {
    'completed',
    'failed',
    'cancelled',
    'review_required',
  };
  Future<Map<String, Map<String, dynamic>>> restore() async {
    final result = <String, Map<String, dynamic>>{};
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = jsonDecode(prefs.getString(key) ?? '[]');
      if (raw is! List || raw.length > 40) return result;
      for (final item in raw) {
        if (item is! Map ||
            item['taskId'] is! String ||
            !RegExp(r'^device_[0-9]{1,24}$').hasMatch(item['taskId']) ||
            item['pluginId'] is! String ||
            (item['pluginId'] as String).length > 120 ||
            item['digest'] is! String ||
            (item['digest'] as String).length > 128 ||
            item['summary'] is! String ||
            (item['summary'] as String).length > 1600 ||
            item['actions'] is! int ||
            item['actions'] < 0 ||
            item['actions'] > 30 ||
            item['rounds'] is! int ||
            item['rounds'] < 0 ||
            item['rounds'] > 30)
          continue;
        final data = Map<String, dynamic>.from(item);
        if (!terminal.contains(data['state'])) {
          data['state'] = 'review_required';
          data['errorCode'] = 'PROCESS_RESTART';
          data['summary'] = '上次任务因 App 进程结束而中断，请核对已完成的操作；不会自动继续或重放。';
        }
        result[data['taskId']] = data;
      }
    } catch (_) {
      /* A corrupt receipt never schedules work or blocks startup. */
    }
    return result;
  }

  Future<void> save(Map<String, Map<String, dynamic>> tasks) async {
    final values = tasks.values.toList();
    final recent = values
        .skip((values.length - 40).clamp(0, values.length))
        .map(
          (data) => {
            for (final field in [
              'taskId',
              'pluginId',
              'digest',
              'state',
              'summary',
              'actions',
              'rounds',
              'errorCode',
            ])
              field: data[field],
          },
        )
        .toList();
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(key, jsonEncode(recent)))
      throw StateError('Device receipt could not be saved');
  }
}

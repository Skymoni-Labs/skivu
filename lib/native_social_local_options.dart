import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Presentation preferences from the original local social interface.
/// Notification switches do not request system permission or contact a service.
class NativeSocialLocalOptions extends ChangeNotifier {
  static const storageKey = 'skivu.native-social.preferences.v1';
  int fontSize = 16;
  bool notifications = true, quiet = false;
  String note = '';
  Future<void> _writes = Future.value();
  bool _restored = false;
  Future<void> restore() async {
    if (_restored) return;
    _restored = true;
    try {
      final raw = (await SharedPreferences.getInstance()).getString(storageKey);
      if (raw != null) {
        final value = jsonDecode(raw) as Map;
        _readSnapshot(value);
      }
    } catch (_) {
      /* Existing invalid local preview options are not a chat error. */
    }
    notifyListeners();
  }

  /// Refresh mounted readers only after an external, verified local write.
  /// Does not enqueue another write or couple migration retries to the UI queue.
  void reloadSnapshot(Map<String, dynamic> value) {
    _readSnapshot(value);
    notifyListeners();
  }

  void _readSnapshot(Map value) {
    fontSize =
        value['fontSize'] is int &&
            [13, 14, 15, 16, 18].contains(value['fontSize'])
        ? value['fontSize'] as int
        : 16;
    notifications = value['notifications'] != false;
    quiet = value['quiet'] == true;
    note = value['note'] is String
        ? (value['note'] as String).substring(
            0,
            (value['note'] as String).length.clamp(0, 4000),
          )
        : '';
  }

  Future<void> _save() async {
    final raw = jsonEncode({
      'fontSize': fontSize,
      'notifications': notifications,
      'quiet': quiet,
      'note': note,
    });
    _writes = _writes.then((_) async {
      await (await SharedPreferences.getInstance()).setString(storageKey, raw);
    });
    notifyListeners();
    await _writes;
  }

  Future<void> setFont(int value) async {
    if (![13, 14, 15, 16, 18].contains(value)) return;
    fontSize = value;
    await _save();
  }

  Future<void> setNotification(bool value) async {
    notifications = value;
    await _save();
  }

  Future<void> setQuiet(bool value) async {
    quiet = value;
    await _save();
  }

  Future<void> setNote(String value) async {
    if (value.length > 4000) return;
    note = value;
    await _save();
  }
}

final nativeSocialLocalOptions = NativeSocialLocalOptions();

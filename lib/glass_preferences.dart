import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

typedef GlassBlurValues = ({
  double left,
  double right,
  double user,
  double assistant,
});

GlassBlurValues decodeGlassBlurValues(String raw) {
  final value = jsonDecode(raw) as Map<String, dynamic>;
  double number(String key, double fallback) {
    final v = value[key];
    return v is num && v.isFinite ? v.toDouble().clamp(0, 30) : fallback;
  }

  return (
    left: number('left', 12),
    right: number('right', 12),
    user: number('user', 0),
    assistant: number('assistant', 0),
  );
}

abstract interface class GlassPreferencesPersistence {
  Future<GlassBlurValues?> read();
  Future<void> write(GlassBlurValues values);
}

class LocalGlassPreferencesPersistence implements GlassPreferencesPersistence {
  late final _prefs = SharedPreferencesAsync();
  static const _key = 'skivu.sidebarGlass.v1';

  @override
  Future<GlassBlurValues?> read() async {
    final raw = await _prefs.getString(_key);
    if (raw == null) return null;
    return decodeGlassBlurValues(raw);
  }

  @override
  Future<void> write(GlassBlurValues values) => _prefs.setString(
    _key,
    jsonEncode({
      'left': values.left,
      'right': values.right,
      'user': values.user,
      'assistant': values.assistant,
    }),
  );
}

class GlassPreferences extends ChangeNotifier {
  GlassPreferences({GlassPreferencesPersistence? persistence})
    : _persistence = persistence ?? LocalGlassPreferencesPersistence();
  final GlassPreferencesPersistence _persistence;
  double _left = 12, _right = 12;
  double _user = 0, _assistant = 0;
  double get leftBlur => _left;
  double get rightBlur => _right;
  double get userBlur => _user;
  double get assistantBlur => _assistant;
  String? error;
  Future<void>? _writes;
  int _saveGeneration = 0;

  Future<void> restore() async {
    try {
      error = null;
      final saved = await _persistence.read();
      if (saved != null) {
        _left = saved.left.isFinite ? saved.left.clamp(0, 30) : 12;
        _right = saved.right.isFinite ? saved.right.clamp(0, 30) : 12;
        _user = saved.user.isFinite ? saved.user.clamp(0, 30) : 0;
        _assistant = saved.assistant.isFinite
            ? saved.assistant.clamp(0, 30)
            : 0;
      }
    } catch (_) {
      error = '玻璃模糊设置无法读取，已使用默认值。';
      _left = _right = 12;
      _user = _assistant = 0;
    }
    notifyListeners();
  }

  void setBlur({required bool leftSide, required double value}) {
    if (!value.isFinite) return;
    if (leftSide) {
      _left = value.clamp(0, 30);
    } else {
      _right = value.clamp(0, 30);
    }
    error = null;
    notifyListeners();
  }

  Future<void> save() async {
    final generation = ++_saveGeneration;
    final snapshot = (
      left: _left,
      right: _right,
      user: _user,
      assistant: _assistant,
    );
    final previous = _writes;
    final write = previous == null
        ? _persistence.write(snapshot)
        : previous.then((_) => _persistence.write(snapshot));
    _writes = write.catchError((Object _) {});
    try {
      await write;
      if (generation == _saveGeneration && error != null) {
        error = null;
        notifyListeners();
      }
    } catch (_) {
      if (generation == _saveGeneration) {
        error = '玻璃模糊暂未保存，请重新调整后重试。';
        notifyListeners();
      }
    }
  }

  Future<void> reset() async {
    _left = _right = 12;
    error = null;
    notifyListeners();
    await save();
  }

  void setBubbleBlur({required bool user, required double value}) {
    if (!value.isFinite) return;
    if (user) {
      _user = value.clamp(0, 30);
    } else {
      _assistant = value.clamp(0, 30);
    }
    error = null;
    notifyListeners();
  }

  Future<void> resetBubbles() async {
    _user = _assistant = 0;
    error = null;
    notifyListeners();
    await save();
  }
}

final glassPreferences = GlassPreferences();

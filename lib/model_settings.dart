import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'model_connection.dart';

class ModelSettings extends ChangeNotifier {
  ModelSettings({FlutterSecureStorage? secure})
    : _secure = secure ?? const FlutterSecureStorage();
  final FlutterSecureStorage _secure;
  final List<ModelConnection> connections = [];
  Future<void> _mutations = Future.value();
  int _pendingThinkingUpdates = 0;
  String? activeId, error;
  static const _prefsKey = 'skivu.models.v1';
  ModelConnection? get active =>
      connections.where((c) => c.id == activeId).firstOrNull;
  bool get thinkingUpdatePending => _pendingThinkingUpdates > 0;

  Future<void> _mutate(Future<void> Function() operation) {
    final result = _mutations.then((_) => operation());
    _mutations = result.catchError((Object _) {});
    return result;
  }

  Future<void> restore() => _mutate(_restore);

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final text = prefs.getString(_prefsKey);
      if (text == null) return;
      final raw = jsonDecode(text) as Map<String, dynamic>;
      final loaded = (raw['connections'] as List)
          .map((c) => ModelConnection.fromJson(Map<String, dynamic>.from(c)))
          .toList();
      connections
        ..clear()
        ..addAll(loaded);
      activeId = raw['activeId'] as String?;
      if (active == null) activeId = connections.firstOrNull?.id;
    } catch (_) {
      error = '模型配置读取失败，请重新检查设置。';
    }
    notifyListeners();
  }

  Future<String> keyFor(String id) async =>
      await _secure.read(
        key:
            'skivu.api.${connections.where((c) => c.id == id).firstOrNull?.credentialId ?? id}',
      ) ??
      '';

  Future<void> _write(List<ModelConnection> profiles, String? selected) async {
    final prefs = await SharedPreferences.getInstance();
    try {
      if (!await prefs.setString(
        _prefsKey,
        jsonEncode({
          'connections': profiles.map((p) => p.toJson()).toList(),
          'activeId': selected,
        }),
      )) {
        throw StateError('无法保存模型配置');
      }
    } catch (_) {
      // SharedPreferences updates its memory cache before the platform commit.
      try {
        await prefs.reload();
      } catch (_) {}
      rethrow;
    }
  }

  Future<void> save(ModelConnection profile, String key) =>
      _mutate(() => _save(profile, key));

  Future<void> _save(ModelConnection profile, String key) async {
    profile.endpoint();
    final previous = connections.where((c) => c.id == profile.id).firstOrNull;
    final sameKey = previous != null && await keyFor(previous.id) == key.trim();
    final credentialId = sameKey
        ? (previous.credentialId ?? previous.id)
        : '${profile.id}-${DateTime.now().microsecondsSinceEpoch}';
    profile = ModelConnection.fromJson({
      ...profile.toJson(),
      'credentialId': credentialId,
    });
    final next = connections.where((c) => c.id != profile.id).toList()
      ..add(profile);
    final selected = activeId ?? profile.id;
    // A failed secure write must never silently fall back to plain preferences.
    if (!sameKey)
      await _secure.write(key: 'skivu.api.$credentialId', value: key.trim());
    try {
      await _write(next, selected);
    } catch (_) {
      try {
        if (!sameKey) await _secure.delete(key: 'skivu.api.$credentialId');
      } catch (_) {}
      rethrow;
    }
    connections
      ..clear()
      ..addAll(next);
    activeId = selected;
    error = null;
    notifyListeners();
    if (previous != null && !sameKey) {
      try {
        await _secure.delete(
          key: 'skivu.api.${previous.credentialId ?? previous.id}',
        );
      } catch (_) {}
    }
  }

  Future<void> select(String id) => _mutate(() => _select(id));

  Future<void> _select(String id) async {
    if (!connections.any((c) => c.id == id)) return;
    await _write(connections, id);
    activeId = id;
    notifyListeners();
  }

  Future<void> setThinkingEnabled(String id, bool? value) =>
      setGeneration(id, thinkingEnabled: value);

  Future<void> setGeneration(
    String id, {
    int? maxOutput,
    bool? streaming,
    required bool? thinkingEnabled,
  }) {
    _pendingThinkingUpdates++;
    notifyListeners();
    return _mutate(() async {
      final index = connections.indexWhere((c) => c.id == id);
      if (index < 0) throw StateError('模型连接已不存在。');
      final previous = connections[index];
      if (thinkingEnabled != null &&
          thinkingEnabled != previous.thinkingEnabled &&
          !previous.supportsThinking) {
        throw StateError('当前模型连接暂不支持深度思考开关。');
      }
      if (maxOutput != null && maxOutput < 0) {
        throw StateError('最大输出 Token 必须为非负整数。');
      }
      if (previous.thinkingEnabled == thinkingEnabled &&
          (maxOutput == null || previous.maxOutput == maxOutput) &&
          (streaming == null || previous.streaming == streaming))
        return;
      final profile = ModelConnection.fromJson({
        ...previous.toJson(),
        'thinkingEnabled': thinkingEnabled,
        if (maxOutput != null) 'maxOutput': maxOutput,
        if (streaming != null) 'streaming': streaming,
      });
      final next = connections.toList()..[index] = profile;
      await _write(next, activeId);
      connections[index] = profile;
      error = null;
      notifyListeners();
    }).whenComplete(() {
      _pendingThinkingUpdates--;
      notifyListeners();
    });
  }

  Future<void> remove(String id) => _mutate(() => _remove(id));

  Future<void> _remove(String id) async {
    final previous = connections.where((c) => c.id == id).firstOrNull;
    final next = connections.where((c) => c.id != id).toList();
    final selected = activeId == id ? next.firstOrNull?.id : activeId;
    await _write(next, selected);
    connections
      ..clear()
      ..addAll(next);
    activeId = selected;
    notifyListeners();
    await _secure.delete(key: 'skivu.api.${previous?.credentialId ?? id}');
  }
}

final modelSettings = ModelSettings();

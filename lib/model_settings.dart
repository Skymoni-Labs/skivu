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
  String? activeId, error;
  static const _prefsKey = 'skivu.models.v1';
  ModelConnection? get active =>
      connections.where((c) => c.id == activeId).firstOrNull;

  Future<void> restore() async {
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
    if (!await prefs.setString(
      _prefsKey,
      jsonEncode({
        'connections': profiles.map((p) => p.toJson()).toList(),
        'activeId': selected,
      }),
    )) {
      throw StateError('无法保存模型配置');
    }
  }

  Future<void> save(ModelConnection profile, String key) async {
    profile.endpoint();
    final previous = connections.where((c) => c.id == profile.id).firstOrNull;
    final credentialId =
        '${profile.id}-${DateTime.now().microsecondsSinceEpoch}';
    profile = ModelConnection.fromJson({
      ...profile.toJson(),
      'credentialId': credentialId,
    });
    final next = connections.where((c) => c.id != profile.id).toList()
      ..add(profile);
    final selected = activeId ?? profile.id;
    // A failed secure write must never silently fall back to plain preferences.
    await _secure.write(key: 'skivu.api.$credentialId', value: key.trim());
    try {
      await _write(next, selected);
    } catch (_) {
      try {
        await _secure.delete(key: 'skivu.api.$credentialId');
      } catch (_) {}
      rethrow;
    }
    connections
      ..clear()
      ..addAll(next);
    activeId = selected;
    error = null;
    notifyListeners();
    if (previous != null) {
      try {
        await _secure.delete(
          key: 'skivu.api.${previous.credentialId ?? previous.id}',
        );
      } catch (_) {}
    }
  }

  Future<void> select(String id) async {
    if (!connections.any((c) => c.id == id)) return;
    await _write(connections, id);
    activeId = id;
    notifyListeners();
  }

  Future<void> remove(String id) async {
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

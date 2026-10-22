import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'appearance.dart';
import 'glass_preferences.dart';
import 'wallpaper.dart';

abstract interface class ProfilePersistence {
  Future<Map<String, dynamic>?> read();
  Future<void> write(Map<String, dynamic> data);
}

class LocalProfilePersistence implements ProfilePersistence {
  late final _prefs = SharedPreferencesAsync();
  @override
  Future<Map<String, dynamic>?> read() async {
    final raw = await _prefs.getString('skivu.appearanceProfiles.v1');
    return raw == null ? null : jsonDecode(raw) as Map<String, dynamic>;
  }

  @override
  Future<void> write(Map<String, dynamic> data) =>
      _prefs.setString('skivu.appearanceProfiles.v1', jsonEncode(data));
}

class AppearanceProfiles extends ChangeNotifier {
  AppearanceProfiles({
    ProfilePersistence? persistence,
    AppearancePreferences? preferences,
    GlassPreferences? glass,
    WallpaperController? background,
    AppearanceAssets? assets,
  }) : _disk = persistence ?? LocalProfilePersistence(),
       _appearance = preferences ?? appearance,
       _glass = glass ?? glassPreferences,
       _wallpaper = background ?? wallpaper,
       _assets = assets ?? appearanceAssets;
  final ProfilePersistence _disk;
  final AppearancePreferences _appearance;
  final GlassPreferences _glass;
  final WallpaperController _wallpaper;
  final AppearanceAssets _assets;
  List<Map<String, dynamic>> items = [];
  String? active, error;
  bool busy = false;
  Future<void> restore() async {
    try {
      final decoded = await _disk.read();
      if (decoded != null) {
        items = (decoded['items'] as List)
            .take(12)
            .whereType<Map>()
            .where(
              (v) =>
                  v['id'] is String &&
                  RegExp(r'^\d+$').hasMatch(v['id'] as String) &&
                  v['name'] is String &&
                  (v['name'] as String).isNotEmpty &&
                  v['values'] is Map &&
                  v['glass'] is Map,
            )
            .map((v) => Map<String, dynamic>.from(v))
            .toList();
        active = decoded['active'] as String?;
        if (!items.any((p) => p['id'] == active)) active = null;
      }
    } catch (_) {
      items = [];
      active = null;
      error = '外观方案无法读取，当前外观仍可使用。';
    }
    notifyListeners();
  }

  Future<void> _persist() => _disk.write({'active': active, 'items': items});

  Future<void> create(String name) async {
    if (busy) return;
    final title = name.trim();
    if (title.isEmpty || title.length > 40 || items.length >= 12) {
      error = '请输入 1–40 字的名称，最多保存 12 套方案。';
      notifyListeners();
      return;
    }
    busy = true;
    error = null;
    notifyListeners();
    final oldItems = items, oldActive = active;
    try {
      final data = _wallpaper.data;
      final image = data == null
          ? ''
          : await _assets.write('image', data.bytes);
      final id = DateTime.now().microsecondsSinceEpoch.toString();
      items = [
        ...items,
        {
          'id': id,
          'name': title,
          'values': _appearance.values,
          'glass': {
            'left': _glass.leftBlur,
            'right': _glass.rightBlur,
            'user': _glass.userBlur,
            'assistant': _glass.assistantBlur,
          },
          'wallpaper': image,
          'blur': data?.blur ?? 0,
          'dim': data?.dim ?? .12,
        },
      ];
      active = id;
      await _persist();
    } catch (_) {
      items = oldItems;
      active = oldActive;
      error = '方案暂未保存，请重试。';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> rename(String name) async {
    final title = name.trim();
    if (busy || active == null || title.isEmpty || title.length > 40) return;
    final old = items;
    busy = true;
    error = null;
    notifyListeners();
    try {
      items = items
          .map((p) => p['id'] == active ? {...p, 'name': title} : p)
          .toList();
      await _persist();
    } catch (_) {
      items = old;
      error = '名称暂未保存。';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> remove() async {
    if (busy || active == null) return;
    final old = items, oldActive = active;
    busy = true;
    error = null;
    notifyListeners();
    try {
      items = items.where((p) => p['id'] != active).toList();
      active = null;
      await _persist();
    } catch (_) {
      items = old;
      active = oldActive;
      error = '方案暂未删除。';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> apply(String id) async {
    if (busy) return;
    final p = items.where((p) => p['id'] == id).firstOrNull;
    if (p == null) return;
    busy = true;
    error = null;
    notifyListeners();
    try {
      final image = p['wallpaper'] as String? ?? '';
      if (image.isEmpty) {
        await _wallpaper.reset();
      } else {
        await _wallpaper.importImage(
          await _assets.read(image),
          blur: (p['blur'] as num).toDouble(),
          dim: (p['dim'] as num).toDouble(),
        );
      }
      if (_wallpaper.error != null) throw StateError('Wallpaper save failed');
      await _appearance.apply(Map<String, dynamic>.from(p['values'] as Map));
      final g = decodeGlassBlurValues(jsonEncode(p['glass']));
      _glass.setBlur(leftSide: true, value: g.left);
      _glass.setBlur(leftSide: false, value: g.right);
      _glass.setBubbleBlur(user: true, value: g.user);
      _glass.setBubbleBlur(user: false, value: g.assistant);
      await _glass.save();
      if (_appearance.error != null || _glass.error != null)
        throw StateError('Preferences save failed');
      active = id;
      await _persist();
    } catch (_) {
      error = '部分方案参数暂未应用，请重试。';
    } finally {
      busy = false;
      notifyListeners();
    }
  }
}

final appearanceProfiles = AppearanceProfiles();

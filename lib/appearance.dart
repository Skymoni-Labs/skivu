import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_selector/file_selector.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'media_picker_session.dart';
import 'wallpaper.dart';
import 'appearance_files.dart'
    if (dart.library.io) 'appearance_files_io.dart'
    as files;

const appearanceDefaults = <String, dynamic>{
  'accent': 0xff347da3,
  'mode': 'light',
  'font': 'sans',
  'fontAsset': '',
  'textScale': 1.0,
  'uiScale': 1.0,
  'glass': true,
  'reduceMotion': false,
  'backgroundEnabled': true,
  'backgroundOpacity': 1.0,
  'videoAsset': '',
  'videoBlur': 0.0,
  'videoDim': .12,
  'bubbleStyle': 'bubble',
  'compact': false,
  'wideChat': false,
  'rounded': true,
  'userColor': 0xffffffff,
  'assistantColor': 0xffffffff,
  'userText': 0xff285c7a,
  'assistantText': 0xff283947,
  'customMessageColors': false,
  'userOpacity': .62,
  'assistantOpacity': .62,
  'userFont': 'inherit',
  'assistantFont': 'inherit',
  'userFontAsset': '',
  'assistantFontAsset': '',
  'userImage': '',
  'assistantImage': '',
  'avatars': true,
  'squareAvatars': false,
  'inputStyle': 'expanded',
  'floatingInput': true,
  'showStatus': true,
  'showThinking': true,
  'showRole': true,
  'showUser': false,
  'showModel': false,
  'showProvider': false,
  'showTokens': false,
  'showElapsed': false,
  'showTime': false,
  'inputBlur': 2.0,
  'toolbarBlur': 2.0,
  'capsuleToolbar': true,
  'leftOpacity': .40,
  'rightOpacity': .40,
  'inputOpacity': .23,
  'toolbarOpacity': .23,
};
const _limits = <String, (double, double)>{
  'textScale': (.8, 1.4),
  'uiScale': (.8, 1.2),
  'backgroundOpacity': (0, 1),
  'videoBlur': (0, 18),
  'videoDim': (0, .65),
  'userOpacity': (0, 1),
  'assistantOpacity': (0, 1),
  'inputBlur': (0, 30),
  'toolbarBlur': (0, 30),
  'leftOpacity': (0, 1),
  'rightOpacity': (0, 1),
  'inputOpacity': (0, 1),
  'toolbarOpacity': (0, 1),
};
const _choices = <String, List<String>>{
  'mode': ['light', 'dark', 'system'],
  'font': ['sans', 'serif', 'mono', 'custom'],
  'userFont': ['inherit', 'sans', 'serif', 'mono', 'custom'],
  'assistantFont': ['inherit', 'sans', 'serif', 'mono', 'custom'],
  'bubbleStyle': ['bubble', 'document'],
  'inputStyle': ['expanded', 'compact'],
};

Map<String, dynamic> cleanAppearance(Map<String, dynamic> raw) {
  final result = Map<String, dynamic>.from(appearanceDefaults);
  for (final key in result.keys.toList()) {
    final value = raw[key], fallback = result[key];
    if (_limits.containsKey(key)) {
      if (value is num && value.isFinite)
        result[key] = value.toDouble().clamp(
          _limits[key]!.$1,
          _limits[key]!.$2,
        );
    } else if (fallback is bool && value is bool) {
      result[key] = value;
    } else if (fallback is int &&
        value is int &&
        value >= 0 &&
        value <= 0xffffffff) {
      result[key] = value | 0xff000000;
    } else if (fallback is String && value is String && value.length < 150) {
      if (_choices[key]?.contains(value) ??
          (value.isEmpty ||
              RegExp(r'^(font|image|video)-[0-9]+$').hasMatch(value)))
        result[key] = value;
    }
  }
  return result;
}

abstract interface class AppearancePersistence {
  Future<Map<String, dynamic>?> read();
  Future<void> write(Map<String, dynamic> value);
}

class LocalAppearancePersistence implements AppearancePersistence {
  late final _prefs = SharedPreferencesAsync();
  @override
  Future<Map<String, dynamic>?> read() async {
    final raw = await _prefs.getString('skivu.appearance.v1');
    return raw == null ? null : jsonDecode(raw) as Map<String, dynamic>;
  }

  @override
  Future<void> write(Map<String, dynamic> value) =>
      _prefs.setString('skivu.appearance.v1', jsonEncode(value));
}

class AppearanceAssets {
  late final _prefs = SharedPreferencesAsync();
  final _images = <String, Uint8List>{};
  final _fonts = <String>{};
  Uint8List? image(String id) => _images[id];
  Future<Uint8List> read(String id) async => kIsWeb
      ? base64Decode((await _prefs.getString('skivu.asset.$id'))!)
      : files.readAppearanceAsset(id);
  Future<String> write(String kind, Uint8List bytes) async {
    final id = '$kind-${DateTime.now().microsecondsSinceEpoch}';
    if (kIsWeb) {
      await _prefs.setString('skivu.asset.$id', base64Encode(bytes));
    } else {
      await files.writeAppearanceAsset(id, bytes);
    }
    return id;
  }

  Future<String> videoUri(String id) async {
    if (!kIsWeb) return files.appearanceAssetUri(id);
    final bytes = await read(id);
    final webm =
        bytes.length >= 4 &&
        ByteData.sublistView(bytes).getUint32(0) == 0x1a45dfa3;
    return 'data:video/${webm ? 'webm' : 'mp4'};base64,${base64Encode(bytes)}';
  }

  Future<void> loadFont(String id) async {
    if (id.isEmpty || _fonts.contains(id)) return;
    final bytes = await read(id);
    final loader = FontLoader('Skivu-$id')
      ..addFont(Future.value(ByteData.sublistView(bytes)));
    await loader.load();
    _fonts.add(id);
  }

  Future<void> loadImage(String id) async {
    if (id.isEmpty || _images.containsKey(id)) return;
    _images[id] = await read(id);
  }
}

final appearanceAssets = AppearanceAssets();

class AppearancePreferences extends ChangeNotifier {
  AppearancePreferences({AppearancePersistence? persistence})
    : _disk = persistence ?? LocalAppearancePersistence();
  final AppearancePersistence _disk;
  Map<String, dynamic> _values = Map.of(appearanceDefaults);
  Map<String, dynamic> get values => Map.of(_values);
  bool flag(String key) => _values[key] as bool;
  double number(String key) => (_values[key] as num).toDouble();
  String text(String key) => _values[key] as String;
  Color color(String key) => Color(_values[key] as int);
  String? error;
  bool busy = false;
  Future<void>? _writes;
  int _generation = 0;
  bool get dark =>
      text('mode') == 'dark' ||
      (text('mode') == 'system' &&
          WidgetsBinding.instance.platformDispatcher.platformBrightness ==
              Brightness.dark);
  String fontFamily([String key = 'font']) {
    final font = text(key);
    if (font == 'inherit') return fontFamily();
    final id = text(key == 'font' ? 'fontAsset' : '${key}Asset');
    return switch (font) {
      'serif' => 'SkiSerif',
      'mono' => 'SkiMono',
      'custom' when id.isNotEmpty => 'Skivu-$id',
      _ => 'SkiSans',
    };
  }

  void set(String key, dynamic value) {
    if (!appearanceDefaults.containsKey(key)) return;
    final expected = appearanceDefaults[key];
    if (expected is bool && value is! bool) return;
    if (expected is double && (value is! num || !value.isFinite)) return;
    if (expected is int && (value is! int || value < 0 || value > 0xffffffff))
      return;
    if (expected is String &&
        (value is! String ||
            value.length >= 150 ||
            !(_choices[key]?.contains(value) ??
                (value.isEmpty ||
                    RegExp(r'^(font|image|video)-[0-9]+$').hasMatch(value)))))
      return;
    final next = cleanAppearance({..._values, key: value});
    if (mapEquals(next, _values)) return;
    _values = next;
    error = null;
    notifyListeners();
  }

  Future<void> hydrateAssets() async {
    for (final key in ['fontAsset', 'userFontAsset', 'assistantFontAsset']) {
      try {
        await appearanceAssets.loadFont(text(key));
      } catch (_) {
        _values[key] = '';
        error = '部分字体无法读取，请重新选择。';
      }
    }
    for (final key in ['userImage', 'assistantImage']) {
      try {
        await appearanceAssets.loadImage(text(key));
      } catch (_) {
        _values[key] = '';
        error = '部分气泡贴图无法读取，请重新选择。';
      }
    }
  }

  Future<void> restore() async {
    try {
      final saved = await _disk.read();
      if (saved != null) _values = cleanAppearance(saved);
      await hydrateAssets();
    } catch (_) {
      error = '外观配置无法读取，已使用默认外观。';
      _values = Map.of(appearanceDefaults);
    }
    notifyListeners();
  }

  Future<void> apply(Map<String, dynamic> values) async {
    _values = cleanAppearance(values);
    await hydrateAssets();
    notifyListeners();
    await save();
  }

  Future<void> save() async {
    final generation = ++_generation, snapshot = values;
    final previous = _writes;
    final write = previous == null
        ? _disk.write(snapshot)
        : previous.then((_) => _disk.write(snapshot));
    _writes = write.catchError((Object _) {});
    try {
      await write;
      if (generation == _generation && error == '外观暂未保存，请重新调整后重试。') {
        error = null;
        notifyListeners();
      }
    } catch (_) {
      if (generation == _generation) {
        error = '外观暂未保存，请重新调整后重试。';
        notifyListeners();
      }
    }
  }

  Future<void> resetSection(Iterable<String> keys) async {
    for (final key in keys) {
      if (appearanceDefaults.containsKey(key))
        _values[key] = appearanceDefaults[key];
    }
    error = null;
    notifyListeners();
    await save();
  }

  Future<void> pickFont(String key) async {
    if (busy) return;
    busy = true;
    error = null;
    notifyListeners();
    try {
      final selected = await openFile(
        acceptedTypeGroups: [
          const XTypeGroup(
            label: 'Font',
            extensions: ['ttf', 'otf', 'ttc'],
            mimeTypes: [
              'font/ttf',
              'font/otf',
              'font/collection',
              'application/octet-stream',
            ],
          ),
        ],
      );
      if (selected == null) return;
      if (await selected.length() > 32 * 1024 * 1024)
        throw const FormatException();
      final bytes = await selected.readAsBytes();
      if (bytes.length < 12 ||
          !([
            0x00010000,
            0x4f54544f,
            0x74746366,
          ].contains(ByteData.sublistView(bytes).getUint32(0))))
        throw const FormatException();
      final id = await appearanceAssets.write('font', bytes);
      await appearanceAssets.loadFont(id);
      set(key == 'font' ? 'fontAsset' : '${key}Asset', id);
      set(key, 'custom');
      await save();
    } catch (_) {
      error = '字体未导入，请选择有效的 TTF、OTF 或 TTC 文件（最大 32 MB）。';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> pickBubbleImage(bool user) async {
    if (busy) return;
    busy = true;
    error = null;
    notifyListeners();
    try {
      await mediaPickerSession.run(
        user ? MediaDestination.userBubble : MediaDestination.assistantBubble,
        () async {
          final file = await ImagePicker().pickImage(
            source: ImageSource.gallery,
            maxWidth: 1024,
            maxHeight: 1024,
            imageQuality: 85,
            requestFullMetadata: false,
          );
          if (file == null) return;
          await importBubbleImage(user, await file.readAsBytes());
        },
      );
    } catch (_) {
      error = '气泡图片未导入，请选择较小的有效图片。';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> pickVideo() async {
    if (busy) return;
    busy = true;
    error = null;
    notifyListeners();
    try {
      await mediaPickerSession.run(MediaDestination.video, () async {
        final file = await ImagePicker().pickVideo(source: ImageSource.gallery);
        if (file == null) return;
        if (await file.length() > 30 * 1024 * 1024)
          throw const FormatException();
        await importVideo(await file.readAsBytes());
      });
    } catch (_) {
      error = '视频未导入，请选择手机支持的本地视频（最大 30 MB）。';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> importBubbleImage(bool user, Uint8List bytes) async {
    await WallpaperController.validateImage(bytes);
    final id = await appearanceAssets.write('image', bytes);
    await appearanceAssets.loadImage(id);
    set(user ? 'userImage' : 'assistantImage', id);
    await save();
  }

  Future<void> importVideo(Uint8List bytes) async {
    if (bytes.isEmpty || bytes.length > 30 * 1024 * 1024)
      throw const FormatException('Invalid video size');
    set('videoAsset', await appearanceAssets.write('video', bytes));
    set('backgroundEnabled', true);
    await save();
  }

  void reportImportError(String message) {
    error = message;
    notifyListeners();
  }
}

final appearance = AppearancePreferences();

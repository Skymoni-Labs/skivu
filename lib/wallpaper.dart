import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'image_validation.dart'
    if (dart.library.js_interop) 'image_validation_web.dart'
    as validation;
import 'package:shared_preferences/shared_preferences.dart';
import 'media_picker_session.dart';
import 'wallpaper_files.dart'
    if (dart.library.io) 'wallpaper_files_io.dart'
    as files;

class WallpaperData {
  const WallpaperData({
    required this.id,
    required this.bytes,
    this.blur = 0,
    this.dim = .12,
  });
  final String id;
  final Uint8List bytes;
  final double blur, dim;
  WallpaperData styled({double? blur, double? dim}) => WallpaperData(
    id: id,
    bytes: bytes,
    blur: blur ?? this.blur,
    dim: dim ?? this.dim,
  );
}

abstract interface class WallpaperPersistence {
  Future<WallpaperData?> read();
  Future<void> write(WallpaperData? data);
}

/// Native images live in app support, not the picker's temporary cache.
/// Web stores a bounded image in local storage; no upload or remote URL is used.
class LocalWallpaperPersistence implements WallpaperPersistence {
  late final _prefs = SharedPreferencesAsync();
  static const _key = 'skivu.wallpaper.v1';

  @override
  Future<WallpaperData?> read() async {
    final raw = await _prefs.getString(_key);
    if (raw == null) return null;
    final value = jsonDecode(raw) as Map<String, dynamic>;
    return WallpaperData(
      id: value['id'] as String,
      bytes: kIsWeb
          ? base64Decode(value['image'] as String)
          : await files.readWallpaperFile(value['id'] as String),
      blur: ((value['blur'] as num?)?.toDouble() ?? 0).clamp(0, 18),
      dim: ((value['dim'] as num?)?.toDouble() ?? .12).clamp(0, .65),
    );
  }

  @override
  Future<void> write(WallpaperData? data) async {
    final old = await _prefs.getString(_key);
    if (data == null) {
      await _prefs.remove(_key);
    } else {
      if (!kIsWeb) await files.writeWallpaperFile(data.id, data.bytes);
      await _prefs.setString(
        _key,
        jsonEncode({
          'id': data.id,
          'blur': data.blur,
          'dim': data.dim,
          if (kIsWeb) 'image': base64Encode(data.bytes),
        }),
      );
    }
    // A failed preference write retains the previous image and metadata.
    if (!kIsWeb && old != null) {
      try {
        final oldId = (jsonDecode(old) as Map<String, dynamic>)['id'] as String;
        if (oldId != data?.id) await files.deleteWallpaperFile(oldId);
      } catch (_) {
        // Old-file cleanup must not turn a successful save into a failure.
      }
    }
  }
}

class WallpaperController extends ChangeNotifier {
  WallpaperController({
    WallpaperPersistence? persistence,
    Future<Uint8List?> Function()? pickImage,
  }) : _persistence = persistence ?? LocalWallpaperPersistence(),
       _pickImage = pickImage ?? _pickFromGallery,
       _pickerSession = pickImage == null ? mediaPickerSession : null;

  final WallpaperPersistence _persistence;
  final Future<Uint8List?> Function() _pickImage;
  final MediaPickerSession? _pickerSession;
  WallpaperData? _data;
  WallpaperData? get data => _data;
  bool busy = false;
  String? error;
  Future<void>? _writes;

  static Future<Uint8List?> _pickFromGallery() async {
    final image = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 2048,
      maxHeight: 2048,
      imageQuality: 85,
      requestFullMetadata: false,
    );
    return image?.readAsBytes();
  }

  static Future<void> validateImage(Uint8List bytes) async {
    if (bytes.isEmpty || bytes.length > 3 * 1024 * 1024) {
      throw const FormatException('Image must be at most 3 MB after resizing.');
    }
    if (kIsWeb) {
      await validation.validateWebImage(bytes);
      return;
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    ui.ImageDescriptor? descriptor;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      if (descriptor.width * descriptor.height > 16000000) {
        throw const FormatException('Image dimensions are too large.');
      }
      final codec = await descriptor.instantiateCodec(targetWidth: 64);
      try {
        final frame = await codec.getNextFrame();
        frame.image.dispose();
      } finally {
        codec.dispose();
      }
    } finally {
      descriptor?.dispose();
      buffer.dispose();
    }
  }

  Future<void> _save(WallpaperData? snapshot) {
    final previous = _writes;
    final write = previous == null
        ? _persistence.write(snapshot)
        : previous.then((_) => _persistence.write(snapshot));
    _writes = write.catchError((Object _) {});
    return write;
  }

  Future<void> restore() async {
    try {
      final saved = await _persistence.read();
      if (saved != null) await validateImage(saved.bytes);
      _data = saved;
    } catch (_) {
      _data = null;
      error = '上次的壁纸无法读取，请重新选择图片。';
    }
    notifyListeners();
  }

  Future<void> _import(Uint8List bytes, {double? blur, double? dim}) async {
    await validateImage(bytes);
    final next = WallpaperData(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      bytes: bytes,
      blur: blur?.isFinite == true ? blur!.clamp(0, 18) : _data?.blur ?? 0,
      dim: dim?.isFinite == true ? dim!.clamp(0, .65) : _data?.dim ?? .12,
    );
    await _save(next);
    _data = next;
  }

  Future<bool> choose() async {
    if (busy) return false;
    busy = true;
    error = null;
    notifyListeners();
    try {
      Future<bool> select() async {
        final bytes = await _pickImage();
        if (bytes == null) return false;
        await _import(bytes);
        return true;
      }

      return _pickerSession == null
          ? await select()
          : await _pickerSession.run(MediaDestination.wallpaper, select);
    } on FormatException {
      error = '图片无法使用，请选择较小的 JPG、PNG 或 WebP 图片。';
      return false;
    } catch (_) {
      error = '图片选择或保存失败，请重试。';
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> importImage(Uint8List bytes, {double? blur, double? dim}) async {
    if (busy) throw StateError('Wallpaper busy');
    busy = true;
    error = null;
    notifyListeners();
    try {
      await _import(bytes, blur: blur, dim: dim);
    } catch (_) {
      error = '壁纸未能恢复，请重试。';
      rethrow;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  void style({double? blur, double? dim}) {
    if (busy || _data == null) return;
    _data = _data!.styled(
      blur: blur?.isFinite == true ? blur!.clamp(0, 18) : null,
      dim: dim?.isFinite == true ? dim!.clamp(0, .65) : null,
    );
    error = null;
    notifyListeners();
  }

  Future<void> saveStyle() async {
    try {
      await _save(_data);
    } catch (_) {
      error = '壁纸调整暂未保存，请重试。';
      notifyListeners();
    }
  }

  Future<void> reset() async {
    if (busy) return;
    busy = true;
    error = null;
    notifyListeners();
    try {
      await _save(null);
      _data = null;
    } catch (_) {
      error = '恢复默认失败，请重试。';
    } finally {
      busy = false;
      notifyListeners();
    }
  }
}

final wallpaper = WallpaperController();

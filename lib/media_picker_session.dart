import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum MediaDestination {
  wallpaper,
  userBubble,
  assistantBubble,
  video,
  characterAvatar,
  userAvatar,
  chatImage,
  sticker,
}

abstract interface class PendingMediaStore {
  Future<String?> read();
  Future<void> write(String? destination);
}

class LocalPendingMediaStore implements PendingMediaStore {
  late final _prefs = SharedPreferencesAsync();
  static const _key = 'skivu.pendingMedia.v1';
  @override
  Future<String?> read() => _prefs.getString(_key);
  @override
  Future<void> write(String? destination) => destination == null
      ? _prefs.remove(_key)
      : _prefs.setString(_key, destination);
}

/// Remember the intended surface before Android opens an external picker.
class MediaPickerSession {
  MediaPickerSession({PendingMediaStore? store})
    : _store = store ?? LocalPendingMediaStore();
  final PendingMediaStore _store;
  bool _busy = false;
  Future<T> run<T>(
    MediaDestination destination,
    Future<T> Function() action,
  ) async {
    if (_busy) throw StateError('Another media picker is active');
    _busy = true;
    try {
      await _store.write(destination.name);
      try {
        return await action();
      } finally {
        await _clear();
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> _clear() async {
    try {
      await _store.write(null);
    } catch (_) {
      /* Empty lost-data response clears a stale marker next launch. */
    }
  }

  Future<void> recover({
    required Future<void> Function(MediaDestination, Uint8List) import,
    Future<LostDataResponse> Function()? retrieve,
  }) async {
    final pending = await _store.read();
    try {
      final result = await (retrieve ?? ImagePicker().retrieveLostData)();
      if (result.isEmpty) return;
      if (result.exception != null) throw result.exception!;
      final file = result.files?.firstOrNull ?? result.file;
      if (file == null) return;
      final destination =
          MediaDestination.values.where((d) => d.name == pending).firstOrNull ??
          (result.type == RetrieveType.video
              ? MediaDestination.video
              : MediaDestination.wallpaper);
      if (result.type == RetrieveType.video &&
              destination != MediaDestination.video ||
          result.type == RetrieveType.image &&
              destination == MediaDestination.video)
        throw const FormatException('Recovered media type mismatch');
      final limit = destination == MediaDestination.video
          ? 30 * 1024 * 1024
          : 3 * 1024 * 1024;
      if (await file.length() > limit)
        throw const FormatException('Recovered media too large');
      await import(destination, await file.readAsBytes());
    } finally {
      await _clear();
    }
  }
}

final mediaPickerSession = MediaPickerSession();

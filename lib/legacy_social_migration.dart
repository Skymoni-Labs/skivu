import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'state.dart';
import 'social_activity.dart';
import 'ui_plugins.dart';
import 'native_social_local_options.dart';
import 'legacy_social_migration_native.dart'
    if (dart.library.js_interop) 'legacy_social_migration_web.dart'
    as platform;

typedef LegacyArchiveReader = Future<String?> Function({required bool capture});

enum LegacySocialStatus {
  idle,
  reading,
  complete,
  awaitingMode,
  unsupported,
  failed,
}

/// Reads only a locally archived presentation snapshot. No legacy JavaScript,
/// social network, model request, or payment operation is run during import.
/// Call after DemoStore.restore and SocialActivity.restore have completed.
class LegacySocialMigration extends ChangeNotifier {
  LegacySocialMigration({
    DemoStore? store,
    SocialActivity? activity,
    NativeSocialLocalOptions? localOptions,
    LegacyArchiveReader? archiveReader,
    bool? supported,
  }) : store = store ?? demo,
       activity = activity ?? socialActivity,
       localOptions = localOptions ?? nativeSocialLocalOptions,
       _read = archiveReader ?? platform.readArchive,
       _supported = supported ?? platform.supported;

  static const doneKey = 'skivu.legacy-social.import.v1';
  // Separate from the first importer: installations which already migrated
  // profile/posts must still recover the previously archived preview options.
  static const optionsDoneKey = 'skivu.legacy-social.options-import.v1';
  static const schema = 'skivu-legacy-social-v1';
  static const storageKeys = [
    'skivu.host.social.v1',
    'skivu.social-demo.v2',
    'skivu.chat-modes.html.v1',
  ];
  // Shared with the Flutter social profile editor; login credentials are never
  // involved. Existing userCard entries, the name, and the avatar always win.
  static const profileKeys = {
    'account': '社交账号',
    'bio': '个性签名',
    'city': '地区',
    'status': '个人状态',
  };
  final DemoStore store;
  final SocialActivity activity;
  final NativeSocialLocalOptions localOptions;
  final LegacyArchiveReader _read;
  final bool _supported;
  LegacySocialStatus status = LegacySocialStatus.idle;
  String? error;
  Future<bool>? _running;
  bool _disposed = false;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  /// Failures are retryable. A completed archive capture does not imply that
  /// profile/posts were imported; only their successful durable writes do.
  Future<bool> ensure(ChatUiMode mode) async {
    final active = _running;
    if (active != null) {
      await active;
      // A startup in classic mode may be followed by selecting a social mode.
      if (status == LegacySocialStatus.awaitingMode &&
          mode != ChatUiMode.classic) {
        return ensure(mode);
      }
      return status == LegacySocialStatus.complete;
    }
    final next = _ensure(mode);
    _running = next;
    try {
      return await next;
    } finally {
      if (identical(_running, next)) _running = null;
    }
  }

  Future<bool> _ensure(ChatUiMode mode) async {
    error = null;
    if (!_supported) {
      status = LegacySocialStatus.unsupported;
      _changed();
      return false;
    }
    status = LegacySocialStatus.reading;
    _changed();
    try {
      final preferences = await SharedPreferences.getInstance();
      final contentDone = preferences.getBool(doneKey) == true;
      if (contentDone && preferences.getBool(optionsDoneKey) == true) {
        status = LegacySocialStatus.complete;
        _changed();
        return true;
      }
      final raw = await _read(
        capture: true,
      ).timeout(const Duration(seconds: 20));
      if (raw == null) throw StateError('No verified archive');
      final archive = decodeArchive(raw);
      final storage = archive['storage'] as Map;
      await _importLocalOptions(preferences, storage);
      if (contentDone) {
        status = LegacySocialStatus.complete;
        _changed();
        return true;
      }
      final hostText = storage[storageKeys.first] as String?;
      final host = hostText == null
          ? <String, dynamic>{}
          : jsonDecode(hostText);
      if (host is! Map) throw const FormatException('Invalid host snapshot');
      if (store.storageError != null) {
        await store.saveChats();
        if (store.storageError != null) {
          throw StateError('Chat storage unavailable');
        }
      }
      final profile = host['profile'];
      if (profile != null && profile is! Map) {
        throw const FormatException('Invalid profile');
      }
      final additions = <String, String>{};
      if (profile is Map) {
        const limits = {'account': 36, 'bio': 100, 'city': 30, 'status': 100};
        for (final field in profileKeys.entries) {
          final value = profile[field.key];
          if (value == null) continue;
          if (value is! String || value.length > limits[field.key]!) {
            throw const FormatException('Invalid profile field');
          }
          if (!store.userCard.containsKey(field.value)) {
            additions[field.value] = value;
          }
        }
      }
      if (additions.isNotEmpty) {
        store.userCard.addAll(additions);
        store.changed();
        await store.saveChats();
        if (store.storageError != null) {
          for (final entry in additions.entries) {
            if (store.userCard[entry.key] == entry.value) {
              store.userCard.remove(entry.key);
            }
          }
          store.changed();
          throw StateError('Profile could not be saved');
        }
      }
      final posts = host['posts'];
      if (posts != null && posts is! List) {
        throw const FormatException('Invalid legacy posts');
      }
      if (posts is List && posts.isNotEmpty) {
        if (mode == ChatUiMode.classic) {
          status = LegacySocialStatus.awaitingMode;
          _changed();
          return false;
        }
        final failure = await activity.importPosts(
          mode == ChatUiMode.qq ? 'qq' : 'wx',
          posts,
        );
        if (failure != null) {
          error = failure;
          throw StateError('Legacy posts could not be saved');
        }
      }
      if (!await preferences.setBool(doneKey, true)) {
        throw StateError('Completion could not be saved');
      }
      // Neither the original localStorage keys nor the raw archive are removed.
      status = LegacySocialStatus.complete;
      _changed();
      return true;
    } catch (failure) {
      error ??= failure is PlatformException && failure.message != null
          ? failure.message
          : '旧社交资料尚未完成迁移，原数据和已有备份已保留，可重试。';
      status = LegacySocialStatus.failed;
      _changed();
      return false;
    }
  }

  Future<void> _importLocalOptions(
    SharedPreferences preferences,
    Map storage,
  ) async {
    if (preferences.getBool(optionsDoneKey) == true) return;
    Map? object(String key) {
      final raw = storage[key];
      if (raw == null) return null;
      try {
        final value = jsonDecode(raw as String);
        return value is Map ? value : null;
      } on FormatException {
        // A malformed prototype is still preserved verbatim in the archive;
        // it must not prevent unrelated real profile/posts from recovering.
        return null;
      }
    }

    final prototype = object(storageKeys[1]);
    final presentation = object(storageKeys[2]);
    final settings = presentation?['settings'];
    const fonts = [13, 14, 15, 16, 18];
    final nativeFont = settings is Map ? settings['nativeFont'] : null;
    final fallbackFont = settings is Map ? settings['font'] : null;
    final font = nativeFont is int && fonts.contains(nativeFont)
        ? nativeFont
        : fallbackFont is int && fonts.contains(fallbackFont)
        ? fallbackFont
        : null;
    await localOptions.restore();
    final currentRaw = preferences.getString(
      NativeSocialLocalOptions.storageKey,
    );
    final Map<String, dynamic> current;
    if (currentRaw == null) {
      current = {};
    } else {
      final decoded = jsonDecode(currentRaw);
      if (decoded is! Map)
        throw const FormatException('Invalid current options');
      current = Map<String, dynamic>.from(decoded);
    }
    final recovered = <String, dynamic>{
      if (font != null) 'fontSize': font,
      if (prototype?['notifications'] is bool)
        'notifications': prototype!['notifications'],
      if (prototype?['quiet'] is bool) 'quiet': prototype!['quiet'],
      if (prototype?['note'] is String &&
          (prototype!['note'] as String).length <= 4000)
        'note': prototype['note'],
    };
    final additions = {
      for (final entry in recovered.entries)
        if (!current.containsKey(entry.key)) entry.key: entry.value,
    };
    if (additions.isNotEmpty) {
      final merged = {...current, ...additions};
      // Preserve existing false/empty values and unknown future fields. An
      // ordinary UI setter would enqueue a second write and couple retries to
      // its queue; notify mounted readers only after the direct write verifies.
      final encoded = jsonEncode(merged);
      try {
        if (!await preferences.setString(
          NativeSocialLocalOptions.storageKey,
          encoded,
        ))
          throw StateError('Local options could not be saved');
        // SharedPreferences setters update the cache before platform IO. A
        // reload is required to verify durable data rather than our own cache.
        await preferences.reload();
        if (preferences.getString(NativeSocialLocalOptions.storageKey) !=
            encoded)
          throw StateError('Local options read-back did not match');
      } catch (_) {
        // A failed setter may still have updated its cache. Restore the prior
        // destination so retry never mistakes an uncommitted import for newer
        // user data. The verified raw legacy archive is never touched.
        if (currentRaw == null) {
          await preferences.remove(NativeSocialLocalOptions.storageKey);
        } else {
          await preferences.setString(
            NativeSocialLocalOptions.storageKey,
            currentRaw,
          );
        }
        rethrow;
      }
      localOptions.reloadSnapshot(merged);
    }
    if (!await preferences.setBool(optionsDoneKey, true))
      throw StateError('Local options completion could not be saved');
  }

  static Map<String, dynamic> decodeArchive(String raw) {
    if (utf8.encode(raw).length > 24 * 1024 * 1024) {
      throw const FormatException('Archive too large');
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map ||
        decoded['schema'] != schema ||
        decoded['source'] is! String ||
        !['android', 'web'].contains(decoded['platform']) ||
        decoded['storage'] is! Map) {
      throw const FormatException('Invalid legacy archive');
    }
    if (decoded['platform'] == 'android' &&
        decoded['source'] !=
            'file:///android_asset/flutter_assets/assets/social_ui/index.html') {
      throw const FormatException('Invalid legacy origin');
    }
    final storage = decoded['storage'] as Map;
    if (storage.length != storageKeys.length ||
        storageKeys.any(
          (key) =>
              !storage.containsKey(key) ||
              (storage[key] != null && storage[key] is! String),
        )) {
      throw const FormatException('Invalid legacy storage keys');
    }
    return Map<String, dynamic>.from(decoded);
  }

  /// Raw JSON includes prototype-only data that is intentionally not converted
  /// into real conversations. A caller may offer it through a JSON save dialog.
  Future<String?> readBackup() async {
    if (!_supported) return null;
    final raw = await _read(
      capture: false,
    ).timeout(const Duration(seconds: 20));
    if (raw != null) decodeArchive(raw);
    return raw;
  }

  Future<String?> exportBackup() => readBackup();

  /// Android reuses the existing user-confirmed JSON document picker.
  Future<bool> saveBackupFile() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return false;
    final raw = await readBackup();
    if (raw == null) return false;
    return await const MethodChannel('skivu/chat_backup').invokeMethod<bool>(
          'export',
          {'bytes': Uint8List.fromList(utf8.encode(raw))},
        ) ??
        false;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

final legacySocialMigration = LegacySocialMigration();

import 'chat_storage_files.dart';
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart';

/// Two generations in one directory: incomplete temporary writes are never read.
class PlatformChatStorage implements ChatStorageFiles {
  PlatformChatStorage({this.directory});
  final Directory? directory;
  bool get available => true;
  bool _recovered = false;
  Future<void> _operations = Future.value();
  void Function(String)? _validator;
  Future<Directory> _dir() async {
    final dir =
        directory ??
        Directory('${(await getApplicationSupportDirectory()).path}/chats');
    await dir.create(recursive: true);
    return dir;
  }

  Future<String> _read(File file) async {
    final text = await file.readAsString();
    await compute(_validateArchive, text);
    _validator?.call(text);
    return text;
  }

  Future<String?> read({void Function(String)? validate}) async {
    _validator = validate;
    final dir = await _dir();
    final current = File('${dir.path}/archive.json');
    final previous = File('${dir.path}/archive.previous.json');
    final hasCurrent = await current.exists();
    final hasPrevious = await previous.exists();
    if (!hasCurrent && !hasPrevious) return null;
    if (hasCurrent) {
      try {
        return await _read(current);
      } catch (_) {
        /* Try last verified generation. */
      }
    }
    if (hasPrevious) {
      final text = await _read(previous);
      _recovered = true;
      return text;
    }
    throw const FormatException('Chat archive damaged; original retained');
  }

  Future<void> clear(String value) {
    final operation = _operations.then((_) async {
      await _write(value, recover: true);
      // Both live generations must contain the cleared snapshot before old
      // recovery material is removed. A damaged primary cannot revive chats.
      await _write(value);
      final dir = await _dir();
      final managed = RegExp(
        r'^archive\.(?:damaged\.\d+|replaced\.(?:current|previous)\.\d+)\.json$',
      );
      await for (final entry in dir.list(followLinks: false)) {
        final name = entry.uri.pathSegments.last;
        if (entry is File && managed.hasMatch(name)) await entry.delete();
      }
    });
    _operations = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> write(String value, {bool recover = false}) {
    final operation = _operations.then((_) => _write(value, recover: recover));
    _operations = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> _write(String value, {bool recover = false}) async {
    await compute(_validateArchive, value);
    _validator?.call(value);
    final dir = await _dir();
    final current = File('${dir.path}/archive.json');
    final previous = File('${dir.path}/archive.previous.json');
    final temporary = File('${dir.path}/archive.pending.json');
    // Refuse to replace a damaged archive unless a verified previous generation exists.
    if (!recover && await current.exists()) {
      try {
        await _read(current);
      } catch (_) {
        await _read(previous);
        _recovered = true;
      }
    }
    await temporary.writeAsString(value, flush: true);
    if (await _read(temporary) != value)
      throw StateError('Archive verification failed');
    if (recover) {
      // Explicit replacement retains originals even when neither is readable.
      final stamp = DateTime.now().microsecondsSinceEpoch;
      if (await previous.exists()) {
        await previous.copy(
          '${dir.path}/archive.replaced.previous.$stamp.json',
        );
      }
      if (await current.exists()) {
        await current.copy('${dir.path}/archive.replaced.current.$stamp.json');
        if (await previous.exists()) await previous.delete();
        await current.rename(previous.path);
      }
    } else if (await current.exists()) {
      if (_recovered) {
        await current.rename(
          '${dir.path}/archive.damaged.${DateTime.now().microsecondsSinceEpoch}.json',
        );
      } else {
        if (await previous.exists()) await previous.delete();
        await current.rename(previous.path);
      }
    }
    // If interrupted here, read() finds the previous generation.
    await temporary.rename(current.path);
    _recovered = false;
  }
}

void _validateArchive(String value) {
  final raw = jsonDecode(value);
  if (raw is! Map ||
      raw['schema'] != 'skivu-chats-v1' ||
      raw['conversations'] is! List) {
    throw const FormatException('Invalid chat archive');
  }
}

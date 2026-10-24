// SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'open_plugin.dart' show pluginRelativePath;

Future<Directory> _root(String id) async {
  if (!RegExp(r'^[a-z0-9]+(?:[.-][a-z0-9]+)+$').hasMatch(id))
    throw const FormatException('Invalid plugin ID');
  return Directory(
    '${(await getApplicationSupportDirectory()).path}/open-plugins/$id',
  )..createSync(recursive: true);
}

Future<void> _atomic(File f, List<int> bytes) async {
  await f.parent.create(recursive: true);
  final temp = File('${f.path}.pending');
  await temp.writeAsBytes(bytes, flush: true);
  await temp.rename(f.path);
}

Future<String> readPackage(String id) async =>
    File('${(await _root(id)).path}/package.json').readAsString();
Future<void> writePackage(String id, String raw) async =>
    _atomic(File('${(await _root(id)).path}/package.json'), utf8.encode(raw));
Future<void> removePackage(String id) async {
  final f = File('${(await _root(id)).path}/package.json');
  if (await f.exists()) await f.delete();
}

Future<File> _data(String id, String key) async {
  if (!RegExp(r'^[a-z0-9.-]{1,80}$').hasMatch(key))
    throw const FormatException('Invalid data key');
  return File('${(await _root(id)).path}/$key.json');
}

Future<String?> readData(String id, String key) async {
  final f = await _data(id, key);
  return await f.exists() ? await f.readAsString() : null;
}

Future<void> writeData(String id, String key, String text) async =>
    _atomic(await _data(id, key), utf8.encode(text));
Future<void> clearData(String id) async {
  final root = await _root(id);
  await for (final f in root.list(followLinks: false)) {
    if (f is File && f.uri.pathSegments.last == 'package.json') continue;
    if (f is Link)
      await f.delete();
    else if (f is Directory)
      await f.delete(recursive: true);
    else
      await f.delete();
  }
}

Future<File> _file(String id, String path) async {
  if (!pluginRelativePath(path))
    throw const FormatException('Invalid workspace path');
  final root = await _root(id);
  return File('${root.path}/workspace/$path');
}

Future<Uint8List?> readFile(String id, String path) async {
  final f = await _file(id, path);
  if (!await f.exists()) return null;
  if (await f.length() > 8 * 1024 * 1024) throw StateError('File too large');
  return f.readAsBytes();
}

Future<void> writeFile(String id, String path, Uint8List data) async {
  if (data.length > 8 * 1024 * 1024) throw StateError('File too large');
  final f = await _file(id, path),
      dir = Directory('${(await _root(id)).path}/workspace');
  var total = data.length;
  if (await dir.exists()) {
    await for (final item in dir.list(recursive: true, followLinks: false)) {
      if (item is File && item.path != f.path) total += await item.length();
    }
  }
  if (total > 128 * 1024 * 1024) throw StateError('Workspace full');
  await _atomic(f, data);
}

Future<List<String>> listFiles(String id) async {
  final dir = Directory('${(await _root(id)).path}/workspace');
  if (!await dir.exists()) return [];
  return [
    await for (final f in dir.list(recursive: true, followLinks: false))
      if (f is File)
        f.path.substring(dir.path.length + 1).replaceAll('\\', '/'),
  ];
}

Future<void> removeFile(String id, String path) async {
  final f = await _file(id, path);
  if (await f.exists()) await f.delete();
}

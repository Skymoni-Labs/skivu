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
  return f.readAsBytes();
}

Future<void> writeFile(String id, String path, Uint8List data) async {
  final f = await _file(id, path);
  await _atomic(f, data);
}

Future<Map<String, dynamic>> readRange(
  String id,
  String path,
  int offset,
  int length,
) async {
  if (offset < 0 || length < 1) throw const FormatException('Invalid range');
  final file = await _file(id, path), input = await file.open();
  try {
    final bytes = await input.length();
    await input.setPosition(offset);
    final data = await input.read(length.clamp(1, 1024 * 1024));
    return {
      'base64': base64Encode(data),
      'offset': offset,
      'nextOffset': offset + data.length,
      'bytes': bytes,
      'complete': offset + data.length >= bytes,
    };
  } finally {
    await input.close();
  }
}

Future<Map<String, dynamic>> writeStream(
  String id,
  String path,
  Stream<List<int>> stream,
) async {
  final file = await _file(id, path);
  if (await file.exists()) throw StateError('下载目标已存在，请选择新版本路径。');
  await file.parent.create(recursive: true);
  final temporary = File(
    '${file.path}.download-${DateTime.now().microsecondsSinceEpoch}',
  );
  final sink = temporary.openWrite();
  var bytes = 0;
  try {
    await for (final chunk in stream) {
      sink.add(chunk);
      bytes += chunk.length;
    }
    await sink.flush();
  } finally {
    await sink.close();
  }
  if (await file.exists()) throw StateError('下载目标已变化；完整临时文件保留。');
  await temporary.rename(file.path);
  return {
    'path': path,
    'bytes': bytes,
    'complete': true,
    'storage': 'plugin_workspace',
  };
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

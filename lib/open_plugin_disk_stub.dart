// SPDX-License-Identifier: GPL-3.0-only
import 'dart:typed_data';

Never _unsupported() => throw UnsupportedError('开放插件运行时目前需要 Android App。');
Future<String> readPackage(String id) async => _unsupported();
Future<void> writePackage(String id, String raw) async => _unsupported();
Future<void> removePackage(String id) async => _unsupported();
Future<String?> readData(String id, String key) async => _unsupported();
Future<void> writeData(String id, String key, String raw) async =>
    _unsupported();
Future<void> clearData(String id) async => _unsupported();
Future<Uint8List?> readFile(String id, String path) async => _unsupported();
Future<void> writeFile(String id, String path, Uint8List data) async =>
    _unsupported();
Future<List<String>> listFiles(String id) async => _unsupported();
Future<void> removeFile(String id, String path) async => _unsupported();

import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';

Future<File> _file(String id) async {
  if (!RegExp(r'^\d+$').hasMatch(id)) throw const FormatException('Invalid ID');
  final directory = await getApplicationSupportDirectory();
  await directory.create(recursive: true);
  return File('${directory.path}/wallpaper-$id.img');
}

Future<Uint8List> readWallpaperFile(String id) async =>
    (await _file(id)).readAsBytes();

Future<void> writeWallpaperFile(String id, Uint8List bytes) async {
  final file = await _file(id);
  if (await file.exists()) return;
  final temporary = File('${file.path}.tmp');
  await temporary.writeAsBytes(bytes, flush: true);
  await temporary.rename(file.path);
}

Future<void> deleteWallpaperFile(String id) async {
  final file = await _file(id);
  if (await file.exists()) await file.delete();
}

import 'dart:typed_data';

Future<Uint8List> readWallpaperFile(String id) =>
    throw UnsupportedError('Local files are unavailable on this platform.');
Future<void> writeWallpaperFile(String id, Uint8List bytes) =>
    throw UnsupportedError('Local files are unavailable on this platform.');
Future<void> deleteWallpaperFile(String id) async {}

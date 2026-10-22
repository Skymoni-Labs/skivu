import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';

Future<File> _asset(String id) async {
  if (!RegExp(r'^(font|image|video)-[0-9]+$').hasMatch(id))
    throw const FormatException('Invalid asset ID');
  final dir = Directory(
    '${(await getApplicationSupportDirectory()).path}/appearance',
  );
  await dir.create(recursive: true);
  return File('${dir.path}/$id');
}

Future<void> writeAppearanceAsset(String id, Uint8List bytes) async {
  final file = await _asset(id);
  final temp = File('${file.path}.tmp');
  await temp.writeAsBytes(bytes, flush: true);
  await temp.rename(file.path);
}

Future<Uint8List> readAppearanceAsset(String id) async =>
    (await _asset(id)).readAsBytes();
Future<String> appearanceAssetUri(String id) async =>
    (await _asset(id)).uri.toString();

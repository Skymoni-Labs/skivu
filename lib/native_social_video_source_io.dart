import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

Future<(VideoPlayerController, Future<void> Function())> socialMediaController(
  Uint8List bytes,
  String mime,
) async {
  if (bytes.isEmpty || bytes.length > 2 * 1024 * 1024)
    throw const FormatException('附件过大');
  final directory = await Directory(
    '${(await getTemporaryDirectory()).path}/social-media-preview',
  ).create(recursive: true);
  final extension = switch (mime) {
    'video/mp4' => 'mp4',
    'video/webm' || 'audio/webm' => 'webm',
    'audio/mpeg' => 'mp3',
    'audio/mp4' => 'm4a',
    'audio/ogg' => 'ogg',
    'audio/wav' => 'wav',
    _ => throw const FormatException('附件类型不支持'),
  };
  final file = File(
    '${directory.path}/${DateTime.now().microsecondsSinceEpoch}.$extension',
  );
  await file.writeAsBytes(bytes, flush: true);
  return (
    VideoPlayerController.file(file),
    () async {
      if (await file.exists()) await file.delete();
    },
  );
}

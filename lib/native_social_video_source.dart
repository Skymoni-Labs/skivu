import 'dart:typed_data';
import 'package:video_player/video_player.dart';

Future<(VideoPlayerController, Future<void> Function())> socialMediaController(
  Uint8List bytes,
  String mime,
) async => (
    VideoPlayerController.networkUrl(Uri.dataFromBytes(bytes, mimeType: mime)),
  () async {},
);

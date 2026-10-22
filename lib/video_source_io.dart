import 'dart:io';
import 'package:video_player/video_player.dart';

VideoPlayerController videoController(String uri) =>
    VideoPlayerController.file(File.fromUri(Uri.parse(uri)));

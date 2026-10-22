import 'package:video_player/video_player.dart';

VideoPlayerController videoController(String uri) =>
    VideoPlayerController.networkUrl(Uri.parse(uri));

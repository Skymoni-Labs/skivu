import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:ski/video_backdrop.dart';

class MemoryVideoPlatform extends VideoPlayerPlatform {
  int plays = 0, pauses = 0, disposed = 0;
  double volume = 1;
  bool looping = false;
  @override
  Future<void> init() async {}
  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async => 1;
  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => Stream.value(
    VideoEvent(
      eventType: VideoEventType.initialized,
      duration: const Duration(seconds: 2),
      size: const Size(320, 180),
    ),
  );
  @override
  Future<void> setLooping(int playerId, bool value) async {
    looping = value;
  }

  @override
  Future<void> setVolume(int playerId, double value) async {
    volume = value;
  }

  @override
  Future<void> play(int playerId) async {
    plays++;
  }

  @override
  Future<void> pause(int playerId) async {
    pauses++;
  }

  @override
  Future<void> dispose(int playerId) async {
    disposed++;
  }

  @override
  Future<void> seekTo(int playerId, Duration position) async {}
  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}
  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;
  @override
  Widget buildViewWithOptions(VideoViewOptions options) =>
      const ColoredBox(color: Colors.blue);
}

void main() {
  testWidgets(
    'background video is muted, pauses offscreen and refreshes glass after ready',
    (tester) async {
      final previous = VideoPlayerPlatform.instance,
          platform = MemoryVideoPlatform();
      VideoPlayerPlatform.instance = platform;
      addTearDown(() => VideoPlayerPlatform.instance = previous);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      var ready = 0;
      Widget page(bool paused) => MaterialApp(
        home: VideoBackdrop(
          id: 'video-1',
          paused: paused,
          fallback: const SizedBox(),
          onReady: () => ready++,
          createController: (_) async => VideoPlayerController.networkUrl(
            Uri.parse('https://example.invalid/local-test.mp4'),
          ),
        ),
      );
      await tester.pumpWidget(page(false));
      await tester.pump();
      await tester.pump();
      expect(platform.volume, 0);
      expect(platform.looping, isTrue);
      expect(platform.plays, greaterThan(0));
      expect(ready, 1);
      final playing = platform.plays;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(platform.pauses, greaterThan(0));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(platform.plays, greaterThan(playing));
      final paused = platform.pauses;
      await tester.pumpWidget(page(true));
      await tester.pump();
      expect(platform.pauses, greaterThan(paused));
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      expect(platform.disposed, 1);
      expect(tester.takeException(), isNull);
    },
  );
}

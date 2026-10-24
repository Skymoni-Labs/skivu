import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:ski/native_social_media_preview.dart';
import 'video_backdrop_test.dart' show MemoryVideoPlatform;

Map<String, dynamic> event(
  String kind,
  String mime, {
  String data = 'AQID',
  String name = '本机附件',
}) => {
  'id': 'native-media-preview-test',
  'kind': kind,
  'created': '2026-10-24T10:00:00',
  'user': true,
  'payload': {'name': name, 'data': 'data:$mime;base64,$data'},
};

void main() {
  testWidgets(
    'inline video has no autoplay and pauses when hidden, backgrounded or opening a detail',
    (tester) async {
      final previous = VideoPlayerPlatform.instance,
          platform = MemoryVideoPlatform();
      VideoPlayerPlatform.instance = platform;
      addTearDown(() => VideoPlayerPlatform.instance = previous);
      var cleaned = 0;
      Widget page({bool active = true, Object? pauseToken}) => MaterialApp(
        home: Scaffold(
          body: Center(
            child: NativeSocialMediaPreview(
              event: event('video', 'video/mp4'),
              active: active,
              pauseToken: pauseToken,
              createController: (_) async => (
                VideoPlayerController.networkUrl(
                  Uri.parse('https://example.invalid/local-only-mocked.mp4'),
                ),
                () async {
                  cleaned++;
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      expect(platform.plays, 0);
      expect(find.byTooltip('播放视频'), findsOneWidget);
      await tester.tap(find.byTooltip('播放视频'));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(platform.plays, greaterThan(0));
      expect(find.byType(VideoPlayer), findsOneWidget);
      expect(tester.widget<Slider>(find.byType(Slider)).onChanged, isNotNull);
      final pauses = platform.pauses;
      await tester.pumpWidget(page(active: false));
      await tester.pump();
      expect(platform.pauses, greaterThan(pauses));
      await tester.pumpWidget(page());
      await tester.pump();
      await tester.tap(find.byTooltip('播放视频'));
      await tester.pump();
      final paused = platform.pauses;
      await tester.pumpWidget(page(pauseToken: 1));
      await tester.pump();
      expect(platform.pauses, greaterThan(paused));
      await tester.tap(find.byTooltip('播放视频'));
      await tester.pump();
      final beforeBackground = platform.pauses;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(platform.pauses, greaterThan(beforeBackground));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      expect(platform.disposed, 1);
      expect(cleaned, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'inline audio plays locally and text files retain previewable original filenames',
    (tester) async {
      final previous = VideoPlayerPlatform.instance,
          platform = MemoryVideoPlatform();
      VideoPlayerPlatform.instance = platform;
      addTearDown(() => VideoPlayerPlatform.instance = previous);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NativeSocialMediaPreview(
              event: event('audio', 'audio/mpeg', name: '录音.mp3'),
              createController: (_) async => (
                VideoPlayerController.networkUrl(
                  Uri.parse('https://example.invalid/mocked.mp3'),
                ),
                () async {},
              ),
            ),
          ),
        ),
      );
      expect(find.text('录音.mp3'), findsOneWidget);
      expect(find.byType(VideoPlayer), findsNothing);
      await tester.tap(find.byTooltip('播放音频'));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(platform.plays, greaterThan(0));
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NativeSocialMediaPreview(
              event: event(
                'file',
                'application/octet-stream',
                name: '原记录.txt',
                data: 'aGVsbG8=',
              ),
            ),
          ),
        ),
      );
      expect(find.text('原记录.txt'), findsOneWidget);
      expect(find.text('hello'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

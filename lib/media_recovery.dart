import 'package:flutter/foundation.dart';
import 'appearance.dart';
import 'wallpaper.dart';
import 'media_picker_session.dart';

Future<void> recoverInterruptedMedia() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
  try {
    await mediaPickerSession.recover(
      import: (destination, bytes) async {
        switch (destination) {
          case MediaDestination.wallpaper:
            await wallpaper.importImage(bytes);
            appearance.set('videoAsset', '');
            appearance.set('backgroundEnabled', true);
            await appearance.save();
          case MediaDestination.userBubble:
            await appearance.importBubbleImage(true, bytes);
          case MediaDestination.assistantBubble:
            await appearance.importBubbleImage(false, bytes);
          case MediaDestination.video:
            await appearance.importVideo(bytes);
        }
      },
    );
  } catch (_) {
    appearance.reportImportError('上次的媒体选择未完成，请在外观设置中重新选择。');
  }
}

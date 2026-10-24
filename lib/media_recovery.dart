import 'package:flutter/foundation.dart';
import 'appearance.dart';
import 'wallpaper.dart';
import 'media_picker_session.dart';
import 'character_avatar.dart';
import 'state.dart';

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
          case MediaDestination.characterAvatar:
            // The editor's unsaved target may no longer exist after process
            // death. Never apply this image to the wallpaper or another role.
            appearance.reportImportError('上次的角色头像选择中断，请在角色卡中重新选择。');
          case MediaDestination.userAvatar:
            demo.userAvatar = await normalizeCharacterAvatar(bytes);
            demo.changed();
            await demo.saveChats();
        }
      },
    );
  } catch (_) {
    appearance.reportImportError('上次的媒体选择未完成，请在外观设置中重新选择。');
  }
}

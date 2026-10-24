import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ski/media_picker_session.dart';
import 'package:ski/social_activity.dart';
import 'package:ski/social_post_draft.dart';
import 'package:ski/state.dart';
import 'media_picker_session_test.dart' show MemoryPendingMedia;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'drafts persist independently by channel and preserve publish retry marker',
    () async {
      final drafts = SocialPostDraftStore();
      expect(await drafts.save('wx', '微信未发', [], publishAttempt: 123), isNull);
      expect(await drafts.save('qq', 'QQ未发', []), isNull);
      final reopened = SocialPostDraftStore();
      expect((await reopened.read('wx'))!.text, '微信未发');
      expect((await reopened.read('wx'))!.publishAttempt, 123);
      expect((await reopened.read('qq'))!.text, 'QQ未发');
      expect(await reopened.clear('wx'), isNull);
      expect(await reopened.read('wx'), isNull);
      expect((await reopened.read('qq'))!.text, 'QQ未发');
    },
  );

  test(
    'interrupted social picker recovers only to unpublished active-channel draft',
    () async {
      final drafts = SocialPostDraftStore();
      await drafts.save('wx', '保留微信', []);
      await drafts.save('qq', 'QQ待发表', []);
      final count = socialActivity.feed('qq').length;
      final messages = demo.conversations.fold<int>(
        0,
        (total, c) => total + c.messages.length,
      );
      final pending = MemoryPendingMedia()
        ..value = MediaDestination.socialPost.name;
      final photo = Uint8List.fromList(
        img.encodePng(img.Image(width: 2, height: 2)),
      );
      await MediaPickerSession(store: pending).recover(
        retrieve: () async => LostDataResponse(
          files: [XFile.fromData(photo)],
          type: RetrieveType.image,
        ),
        import: (destination, bytes) async {
          expect(destination, MediaDestination.socialPost);
          expect(await drafts.recoverImage(bytes), isNull);
        },
      );
      final recovered = (await SocialPostDraftStore().read('qq'))!;
      expect(recovered.text, 'QQ待发表');
      expect(
        recovered.images.single.startsWith('data:image/png;base64,'),
        isTrue,
      );
      expect((await drafts.read('wx'))!.images, isEmpty);
      expect(pending.value, isNull);
      expect(socialActivity.feed('qq').length, count);
      expect(
        demo.conversations.fold<int>(
          0,
          (total, c) => total + c.messages.length,
        ),
        messages,
      );
    },
  );

  test(
    'draft limits reject invalid writes and preserve corrupt original records',
    () async {
      final drafts = SocialPostDraftStore();
      expect(await drafts.save('wx', 'x' * 3001, []), isNotNull);
      expect(
        await drafts.save(
          'wx',
          '',
          List.filled(10, 'data:image/png;base64,AA=='),
        ),
        isNotNull,
      );
      expect(
        await drafts.save('wx', '', ['data:image/png;base64,${'A' * 150000}']),
        isNotNull,
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        SocialPostDraftStore.storageKey,
        'corrupt raw original',
      );
      await expectLater(drafts.read('wx'), throwsFormatException);
      expect(await drafts.save('wx', 'new', []), isNotNull);
      expect(
        prefs.getString(SocialPostDraftStore.storageKey),
        'corrupt raw original',
      );
    },
  );
}

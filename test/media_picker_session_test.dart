import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:ski/media_picker_session.dart';

class MemoryPendingMedia implements PendingMediaStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String? destination) async {
    value = destination;
  }
}

void main() {
  test(
    'interrupted bubble and video choices recover into their original surface',
    () async {
      final disk = MemoryPendingMedia(), bytes = Uint8List.fromList([1, 2, 3]);
      final session = MediaPickerSession(store: disk);
      for (final destination in MediaDestination.values) {
        disk.value = destination.name;
        MediaDestination? imported;
        await session.recover(
          retrieve: () async => LostDataResponse(
            files: [XFile.fromData(bytes)],
            type: destination == MediaDestination.video
                ? RetrieveType.video
                : RetrieveType.image,
          ),
          import: (target, data) async {
            imported = target;
            expect(data, bytes);
          },
        );
        expect(imported, destination);
        expect(disk.value, isNull);
      }
    },
  );
  test(
    'legacy video is never decoded as wallpaper and mismatches leave surfaces untouched',
    () async {
      final disk = MemoryPendingMedia(), bytes = Uint8List.fromList([1]);
      final session = MediaPickerSession(store: disk);
      MediaDestination? imported;
      Future<LostDataResponse> video() async => LostDataResponse(
        file: XFile.fromData(bytes),
        type: RetrieveType.video,
      );
      await session.recover(
        retrieve: video,
        import: (target, _) async {
          imported = target;
        },
      );
      expect(imported, MediaDestination.video);
      disk.value = MediaDestination.userBubble.name;
      imported = null;
      await expectLater(
        session.recover(
          retrieve: video,
          import: (target, _) async {
            imported = target;
          },
        ),
        throwsFormatException,
      );
      expect(imported, isNull);
      expect(disk.value, isNull);
    },
  );
  test(
    'a pending destination spans import and concurrent pickers are rejected',
    () async {
      final disk = MemoryPendingMedia(),
          session = MediaPickerSession(store: MemoryPendingMedia());
      final tracked = MediaPickerSession(store: disk),
          blocked = Completer<void>();
      final first = tracked.run(MediaDestination.assistantBubble, () async {
        expect(disk.value, 'assistantBubble');
        await blocked.future;
      });
      await Future<void>.delayed(Duration.zero);
      await expectLater(
        tracked.run(MediaDestination.video, () async {}),
        throwsStateError,
      );
      expect(disk.value, 'assistantBubble');
      blocked.complete();
      await first;
      expect(disk.value, isNull);
      await expectLater(
        session.run(
          MediaDestination.wallpaper,
          () async => throw StateError('Import failed'),
        ),
        throwsStateError,
      );
    },
  );
}

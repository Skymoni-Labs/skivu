import 'dart:math';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:ski/chat_extras.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'original JPEG encoding and dimensions are retained instead of relabeled PNG',
    () async {
      final source = Uint8List.fromList(
        img.encodeJpg(
          img.Image(width: 2400, height: 1600)
            ..clear(img.ColorRgb8(60, 120, 180)),
        ),
      );
      final result = await normalizeChatPhoto(source);
      expect(identical(result, source), true);
      expect(chatPhotoMime(result), 'image/jpeg');
      expect(img.decodeJpg(result)!.width, 2400);
    },
  );
  test(
    'valid dimensions above former8192 boundary preserve original',
    () async {
      final source = Uint8List.fromList(
        img.encodePng(img.Image(width: 9001, height: 2)),
      );
      expect(identical(await normalizeChatPhoto(source), source), true);
    },
  );
  test(
    'original high detail PNG above former6MiB input cap remains byte exact',
    () async {
      final random = Random(731);
      final raster = img.Image(width: 1550, height: 1550);
      for (final pixel in raster) {
        pixel.setRgb(
          random.nextInt(256),
          random.nextInt(256),
          random.nextInt(256),
        );
      }
      final source = Uint8List.fromList(img.encodePng(raster, level: 0));
      expect(source.length, greaterThan(6 * 1024 * 1024));
      expect(identical(await normalizeChatPhoto(source), source), true);
    },
  );
}

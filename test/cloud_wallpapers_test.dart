import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as image;
import 'package:ski/cloud_wallpapers.dart';

Map<String, dynamic> wallpaperRow({Uint8List? bytes}) {
  final data = bytes ?? Uint8List.fromList([1, 2, 3]);
  final sha = sha256.convert(data).toString();
  return {
    'id': 'a' * 32,
    'name': '月下海岸',
    'description': '月光与海浪',
    'mode': 'dark',
    'color_theme': 'blue',
    'sha256': sha,
    'size_bytes': data.length,
    'width': 240,
    'height': 480,
    'revision': 1,
    'updated_at': 1,
    'position': 0,
    'url': 'https://skymoni.com/app-wallpapers/assets/$sha.jpg',
    'thumbnail_url': 'https://skymoni.com/app-wallpapers/assets/$sha-thumb.jpg',
  };
}

Map<String, dynamic> catalogueData(List<Object> rows) => {
  'schema_version': 1,
  'revision': 5,
  'items': rows,
};

void main() {
  test(
    'same public catalogue is parsed without passing any account credentials',
    () async {
      final service = CloudWallpaperService(
        client: MockClient((request) async {
          expect(request.url.origin, 'https://skymoni.com');
          expect(request.url.path, '/api/app-wallpapers');
          expect(
            request.headers.keys.map((k) => k.toLowerCase()),
            isNot(contains('authorization')),
          );
          expect(
            request.headers.keys.map((k) => k.toLowerCase()),
            isNot(contains('cookie')),
          );
          expect(request.followRedirects, isFalse);
          return http.Response(
            jsonEncode({
              'success': true,
              'data': catalogueData([wallpaperRow()]),
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      final result = await service.fetchCatalog();
      expect(result.revision, 5);
      expect(result.items.single.name, '月下海岸');
      expect(
        CloudWallpaperCatalog.parse(result.toJson()).items.single.mode,
        'dark',
      );
      service.close();
    },
  );

  test(
    'catalogue rejects unsupported sources, invalid dimensions and duplicate IDs',
    () {
      final row = wallpaperRow();
      for (final change in <Map<String, dynamic>>[
        {'url': 'https://outside.example/image.jpg'},
        {'url': '${row['url']}?token=secret'},
        {'thumbnail_url': 'http://skymoni.com/image.jpg'},
        {'width': 9000},
        {'width': 6000, 'height': 6000},
        {'size_bytes': cloudWallpaperLimit + 1},
        {'mode': 'unsupported'},
      ]) {
        expect(
          () => CloudWallpaper.parse({...row, ...change}),
          throwsFormatException,
        );
      }
      expect(
        () => CloudWallpaperCatalog.parse(catalogueData([row, row])),
        throwsFormatException,
      );
      expect(
        () => CloudWallpaperCatalog.parse({
          ...catalogueData([]),
          'schema_version': 2,
        }),
        throwsFormatException,
      );
    },
  );

  test(
    'download verifies original length and hash before returning image bytes',
    () async {
      final bytes = Uint8List.fromList([1, 2, 3]);
      final item = CloudWallpaper.parse(wallpaperRow(bytes: bytes));
      final valid = CloudWallpaperService(
        client: MockClient((request) async => http.Response.bytes(bytes, 200)),
      );
      expect(await valid.download(item), bytes);
      valid.close();
      for (final response in [
        http.Response.bytes([1, 2, 4], 200),
        http.Response.bytes([1, 2], 200),
        http.Response(
          '',
          302,
          headers: {'location': 'https://outside.example/photo'},
        ),
      ]) {
        final service = CloudWallpaperService(
          client: MockClient((_) async => response),
        );
        await expectLater(service.download(item), throwsFormatException);
        service.close();
      }
    },
  );

  test(
    'oversized streaming catalogue is rejected even without Content-Length',
    () async {
      final client = MockClient.streaming(
        (request, body) async => http.StreamedResponse(
          Stream.value(List<int>.filled(1024 * 1024 + 1, 32)),
          200,
        ),
      );
      final service = CloudWallpaperService(client: client);
      await expectLater(service.fetchCatalog(), throwsFormatException);
      service.close();
    },
  );

  test(
    'JPEG preparation preserves safe originals and checks true dimensions',
    () {
      final bytes = image.encodeJpg(image.Image(width: 240, height: 480));
      expect(prepareCloudWallpaper((bytes, 240, 480)), same(bytes));
      expect(
        () => prepareCloudWallpaper((bytes, 480, 240)),
        throwsFormatException,
      );
      final padded = Uint8List(3 * 1024 * 1024 + 1)
        ..setRange(0, bytes.length, bytes);
      final result = prepareCloudWallpaper((padded, 240, 480));
      final decoded = image.JpegDecoder().startDecode(result)!;
      expect(result.length, lessThan(3 * 1024 * 1024));
      expect(decoded.width, 240);
      expect(decoded.height, 480);
    },
  );
}

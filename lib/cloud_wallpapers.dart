import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as image;

const cloudWallpaperCatalogUrl = 'https://skymoni.com/api/app-wallpapers';
const cloudWallpaperLimit = 10 * 1024 * 1024;
const _themes = {
  'cobalt',
  'coral',
  'mint',
  'porcelain',
  'silver',
  'blue',
  'iris',
  'jade',
  'gold',
  'ruby',
};

class CloudWallpaper {
  const CloudWallpaper._(
    this.id,
    this.name,
    this.description,
    this.mode,
    this.colorTheme,
    this.sha,
    this.size,
    this.width,
    this.height,
    this.revision,
    this.updatedAt,
    this.position,
    this.url,
    this.thumbnail,
  );
  final String id, name, description, mode, colorTheme, sha;
  final int size, width, height, revision, updatedAt, position;
  final Uri url, thumbnail;

  static CloudWallpaper parse(Object? value) {
    if (value is! Map<String, dynamic>)
      throw const FormatException('Invalid wallpaper');
    String text(String key, int max) {
      final v = value[key];
      if (v is! String || v.length > max)
        throw const FormatException('Invalid text');
      return v;
    }

    int number(String key, int min, int max) {
      final v = value[key];
      if (v is! int || v < min || v > max)
        throw const FormatException('Invalid number');
      return v;
    }

    final id = text('id', 32), sha = text('sha256', 64);
    final name = text('name', 60), description = text('description', 300);
    final mode = text('mode', 10), theme = text('color_theme', 20);
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(id) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(sha) ||
        name.trim().isEmpty ||
        !{'light', 'dark', 'system'}.contains(mode) ||
        !_themes.contains(theme)) {
      throw const FormatException('Invalid wallpaper metadata');
    }
    final width = number('width', 240, 8192),
        height = number('height', 240, 8192);
    if (width * height > 20000000 || width / height > 3 || height / width > 3) {
      throw const FormatException('Invalid dimensions');
    }
    Uri asset(String key, bool thumb) {
      final uri = Uri.tryParse(text(key, 240));
      final path = '/app-wallpapers/assets/$sha${thumb ? '-thumb' : ''}.jpg';
      if (uri == null ||
          uri.scheme != 'https' ||
          uri.authority != 'skymoni.com' ||
          uri.path != path ||
          uri.hasQuery ||
          uri.hasFragment ||
          uri.userInfo.isNotEmpty) {
        throw const FormatException('Invalid wallpaper source');
      }
      return uri;
    }

    return CloudWallpaper._(
      id,
      name,
      description,
      mode,
      theme,
      sha,
      number('size_bytes', 1, cloudWallpaperLimit),
      width,
      height,
      number('revision', 1, 1 << 53),
      number('updated_at', 0, 1 << 53),
      number('position', -10000, 10000),
      asset('url', false),
      asset('thumbnail_url', true),
    );
  }

  Map<String, Object> toJson() => {
    'id': id,
    'name': name,
    'description': description,
    'mode': mode,
    'color_theme': colorTheme,
    'sha256': sha,
    'size_bytes': size,
    'width': width,
    'height': height,
    'revision': revision,
    'updated_at': updatedAt,
    'position': position,
    'url': url.toString(),
    'thumbnail_url': thumbnail.toString(),
  };
}

class CloudWallpaperCatalog {
  const CloudWallpaperCatalog(this.revision, this.items);
  final int revision;
  final List<CloudWallpaper> items;
  static CloudWallpaperCatalog parse(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['schema_version'] != 1 ||
        value['revision'] is! int ||
        (value['revision'] as int) < 1 ||
        value['items'] is! List ||
        (value['items'] as List).length > 200) {
      throw const FormatException('Invalid catalogue');
    }
    final items = (value['items'] as List).map(CloudWallpaper.parse).toList();
    if (items.map((i) => i.id).toSet().length != items.length) {
      throw const FormatException('Duplicate wallpapers');
    }
    return CloudWallpaperCatalog(
      value['revision'] as int,
      List.unmodifiable(items),
    );
  }

  Map<String, Object> toJson() => {
    'schema_version': 1,
    'revision': revision,
    'items': items.map((i) => i.toJson()).toList(),
  };
}

class CloudWallpaperService {
  CloudWallpaperService({http.Client? client})
    : _client = client ?? http.Client();
  final http.Client _client;
  void close() => _client.close();

  Future<Uint8List> _read(Uri uri, int limit, Duration timeout) async {
    final watch = Stopwatch()..start();
    final request = http.Request('GET', uri)..followRedirects = false;
    request.headers['Accept'] = uri.path.endsWith('.jpg')
        ? 'image/jpeg'
        : 'application/json';
    final response = await _client.send(request).timeout(timeout);
    if (response.statusCode != 200 || (response.contentLength ?? 0) > limit) {
      await response.stream.listen((_) {}).cancel();
      throw const FormatException('Wallpaper request failed');
    }
    final result = Completer<Uint8List>();
    final buffer = BytesBuilder(copy: false);
    late final StreamSubscription<List<int>> subscription;
    subscription = response.stream.listen(
      (chunk) {
        if (result.isCompleted) return;
        if (buffer.length + chunk.length > limit) {
          result.completeError(
            const FormatException('Wallpaper response too large'),
          );
          return;
        }
        buffer.add(chunk);
      },
      onError: (Object e, StackTrace s) {
        if (!result.isCompleted) result.completeError(e, s);
      },
      onDone: () {
        if (!result.isCompleted) result.complete(buffer.takeBytes());
      },
    );
    final remaining = timeout - watch.elapsed;
    final timer = Timer(remaining.isNegative ? Duration.zero : remaining, () {
      if (!result.isCompleted)
        result.completeError(TimeoutException('Wallpaper timeout'));
    });
    try {
      return await result.future;
    } finally {
      timer.cancel();
      await subscription.cancel();
    }
  }

  Future<CloudWallpaperCatalog> fetchCatalog() async {
    final uri = Uri.parse(cloudWallpaperCatalogUrl).replace(
      queryParameters: {
        'check': DateTime.now().millisecondsSinceEpoch.toString(),
      },
    );
    final bytes = await _read(uri, 1024 * 1024, const Duration(seconds: 12));
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map<String, dynamic> || value['success'] != true) {
      throw const FormatException('Catalogue unavailable');
    }
    return CloudWallpaperCatalog.parse(value['data']);
  }

  Future<Uint8List> download(CloudWallpaper item) async {
    CloudWallpaper.parse(item.toJson());
    final bytes = await _read(
      item.url,
      cloudWallpaperLimit,
      const Duration(seconds: 45),
    );
    if (bytes.length != item.size ||
        sha256.convert(bytes).toString() != item.sha) {
      throw const FormatException('Wallpaper checksum mismatch');
    }
    return bytes;
  }
}

/// Verify JPEG dimensions before decoding, and fit the host's existing limits.
/// Original bytes are retained when already within the host's image budget.
Uint8List prepareCloudWallpaper((Uint8List, int, int) input) {
  final (bytes, width, height) = input;
  final decoder = image.JpegDecoder();
  final info = decoder.startDecode(bytes);
  if (info == null ||
      info.width != width ||
      info.height != height ||
      width * height > 20000000 ||
      width < 240 ||
      height < 240) {
    throw const FormatException('Invalid wallpaper image');
  }
  if (bytes.length <= 3 * 1024 * 1024 && width * height <= 16000000)
    return bytes;
  final decoded = decoder.decodeFrame(0);
  if (decoded == null) throw const FormatException('Invalid JPEG');
  final longest = width > height ? width : height;
  final target = longest > 2048 ? 2048 : longest;
  final resized = image.copyResize(
    decoded,
    width: width >= height ? target : null,
    height: height > width ? target : null,
    interpolation: image.Interpolation.average,
  );
  final output = image.encodeJpg(resized, quality: 88);
  if (output.length > 3 * 1024 * 1024)
    throw const FormatException('Wallpaper too large');
  return output;
}

import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:shared_preferences/shared_preferences.dart';

class SocialPostDraft {
  const SocialPostDraft({
    required this.channel,
    required this.text,
    required this.images,
    this.publishAttempt,
  });
  final String channel, text;
  final List<String> images;
  final int? publishAttempt;
}

/// Local unpublished drafts, independent from chat and the published feed.
class SocialPostDraftStore {
  static const storageKey = 'skivu.social-post-drafts.v1';
  static const maxArchiveLength = 2800000;
  Future<void> _writes = Future.value();

  Map<String, dynamic> _decode(String? raw) {
    if (raw == null)
      return {
        'version': 1,
        'activeChannel': 'wx',
        'drafts': <String, dynamic>{},
      };
    if (raw.length > maxArchiveLength) throw const FormatException('草稿记录过大。');
    final data = jsonDecode(raw);
    if (data is! Map ||
        data['version'] != 1 ||
        !['wx', 'qq'].contains(data['activeChannel']) ||
        data['drafts'] is! Map ||
        (data['drafts'] as Map).length > 2)
      throw const FormatException('草稿记录格式不正确。');
    for (final entry in (data['drafts'] as Map).entries) {
      final draft = entry.value;
      if (!['wx', 'qq'].contains(entry.key) ||
          draft is! Map ||
          draft['text'] is! String ||
          (draft['text'] as String).length > 3000 ||
          draft['images'] is! List ||
          !_validImages(draft['images'] as List) ||
          draft['publishAttempt'] != null && draft['publishAttempt'] is! int)
        throw const FormatException('草稿内容格式不正确。');
    }
    return Map<String, dynamic>.from(data);
  }

  bool _validImages(List images) =>
      images.length <= 9 &&
      images.every(
        (v) =>
            v is String &&
            v.length <= 150000 &&
            RegExp(
              r'^data:image/(png|jpeg|webp);base64,[A-Za-z0-9+/=]+$',
            ).hasMatch(v),
      );

  Future<SocialPostDraft?> read(String channel) async {
    if (!['wx', 'qq'].contains(channel))
      throw const FormatException('草稿渠道不正确。');
    await _writes;
    final data = _decode(
      (await SharedPreferences.getInstance()).getString(storageKey),
    );
    final draft = (data['drafts'] as Map)[channel];
    if (draft == null) return null;
    return SocialPostDraft(
      channel: channel,
      text: draft['text'] as String,
      images: List<String>.from(draft['images'] as List),
      publishAttempt: draft['publishAttempt'] as int?,
    );
  }

  Future<String?> save(
    String channel,
    String text,
    List<String> images, {
    int? publishAttempt,
  }) {
    if (!['wx', 'qq'].contains(channel) ||
        text.length > 3000 ||
        !_validImages(images))
      return Future.value('草稿内容超出限制。');
    final snapshot = List<String>.of(images);
    return _change((data) {
      data['activeChannel'] = channel;
      (data['drafts'] as Map)[channel] = {
        'text': text,
        'images': snapshot,
        if (publishAttempt != null) 'publishAttempt': publishAttempt,
      };
    });
  }

  Future<String?> clear(String channel) => _change((data) {
    (data['drafts'] as Map).remove(channel);
  });

  Future<String?> _change(void Function(Map<String, dynamic>) change) async {
    String? failure;
    _writes = _writes.then((_) async {
      try {
        final prefs = await SharedPreferences.getInstance();
        final data = _decode(prefs.getString(storageKey));
        change(data);
        final raw = jsonEncode(data);
        if (raw.length > maxArchiveLength ||
            !await prefs.setString(storageKey, raw))
          throw StateError('not saved');
      } catch (_) {
        failure = '动态草稿未能保存，已有草稿记录已保留，请重试。';
      }
    });
    await _writes;
    return failure;
  }

  Future<String?> recoverImage(Uint8List bytes) async {
    final image = await normalizeSocialPhoto(bytes);
    return _change((data) {
      final channel = data['activeChannel'] as String;
      final drafts = data['drafts'] as Map;
      final draft = drafts[channel] ?? {'text': '', 'images': <String>[]};
      final images = List<String>.from(draft['images'] as List);
      if (images.length >= 9) throw const FormatException('草稿图片已满。');
      images.add(image);
      drafts[channel] = {'text': draft['text'], 'images': images};
    });
  }
}

final socialPostDrafts = SocialPostDraftStore();

/// SocialActivity accepts data URIs at most 150000 characters (not bytes).
Future<String> normalizeSocialPhoto(Uint8List bytes) async {
  if (bytes.isEmpty || bytes.length > 6 * 1024 * 1024)
    throw const FormatException('请选择6MB以内的图片。');
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  ui.ImageDescriptor? descriptor;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    if (descriptor.width > 8192 || descriptor.height > 8192)
      throw const FormatException('图片尺寸过大。');
    for (final side in [1024, 768, 512, 384, 256, 128]) {
      final longest = descriptor.width > descriptor.height
          ? descriptor.width
          : descriptor.height;
      final ratio = (side / longest).clamp(0.0, 1.0);
      final codec = await descriptor.instantiateCodec(
        targetWidth: (descriptor.width * ratio).round().clamp(1, 1024),
        targetHeight: (descriptor.height * ratio).round().clamp(1, 1024),
      );
      try {
        final image = (await codec.getNextFrame()).image;
        try {
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          if (data != null) {
            final uri =
                'data:image/png;base64,${base64Encode(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes))}';
            if (uri.length <= 150000) return uri;
          }
        } finally {
          image.dispose();
        }
      } finally {
        codec.dispose();
      }
    }
    throw const FormatException('图片无法压缩，请选择其他图片。');
  } finally {
    descriptor?.dispose();
    buffer.dispose();
  }
}

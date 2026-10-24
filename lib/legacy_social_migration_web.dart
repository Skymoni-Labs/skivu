import 'dart:convert';
import 'package:web/web.dart' as web;

bool get supported => true;
const _backupKey = 'skivu.legacy-social.raw.v1';
const _keys = [
  'skivu.host.social.v1',
  'skivu.social-demo.v2',
  'skivu.chat-modes.html.v1',
];

/// The browser is already on the original origin. Do not create an iframe or
/// execute any of the historical presentation scripts.
Future<String?> readArchive({required bool capture}) async {
  final storage = web.window.localStorage;
  final prior = storage.getItem(_backupKey);
  if (prior != null || !capture) return prior;
  final raw = jsonEncode({
    'schema': 'skivu-legacy-social-v1',
    'source': Uri.base.origin,
    'platform': 'web',
    'capturedAt': DateTime.now().toUtc().toIso8601String(),
    'storage': {for (final key in _keys) key: storage.getItem(key)},
  });
  if (utf8.encode(raw).length > 24 * 1024 * 1024) {
    throw const FormatException('Legacy storage is too large');
  }
  // setItem replaces one value atomically; quota/security errors leave the
  // original three keys intact and are surfaced for retry.
  storage.setItem(_backupKey, raw);
  if (storage.getItem(_backupKey) != raw) {
    throw StateError('Legacy backup could not be verified');
  }
  return raw;
}

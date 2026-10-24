import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

bool get supported =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

Future<String?> readArchive({required bool capture}) async {
  if (!supported) throw UnsupportedError('Legacy social storage');
  return const MethodChannel(
    'skivu/app_platform',
  ).invokeMethod<String>(capture ? 'legacySocialRead' : 'legacySocialBackup');
}

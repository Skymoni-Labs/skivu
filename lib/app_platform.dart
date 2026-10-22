import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class AppDeviceInfo {
  const AppDeviceInfo({
    required this.version,
    required this.versionCode,
    required this.packageName,
    required this.sdk,
    required this.abis,
    required this.signerSha256,
  });
  final String version, packageName, signerSha256;
  final int versionCode, sdk;
  final List<String> abis;

  factory AppDeviceInfo.fromMap(Map raw) => AppDeviceInfo(
    version: raw['version'] as String,
    versionCode: (raw['versionCode'] as num).toInt(),
    packageName: raw['packageName'] as String,
    sdk: (raw['sdk'] as num).toInt(),
    abis: (raw['abis'] as List).cast<String>(),
    signerSha256: raw['signerSha256'] as String,
  );
}

class AppPlatform {
  static const _channel = MethodChannel('skivu/app_platform');
  bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<AppDeviceInfo> info() async =>
      AppDeviceInfo.fromMap(await _channel.invokeMethod<Map>('info') ?? {});
  Future<void> openWebsite(String url) async {
    final uri = Uri.parse(url);
    if (uri.scheme != 'https' ||
        uri.host != 'skymoni.com' ||
        uri.userInfo.isNotEmpty ||
        (uri.hasPort && uri.port != 443)) {
      throw const FormatException('授权页面地址无效。');
    }
    await _channel.invokeMethod('openWebsite', {'url': url});
  }

  Future<String> prepareUpdate() async =>
      await _channel.invokeMethod<String>('prepareUpdate') ??
      (throw StateError('无法准备更新目录'));
  Future<String> installUpdate(
    String path,
    String hash,
    int versionCode,
  ) async =>
      await _channel.invokeMethod<String>('installUpdate', {
        'path': path,
        'sha256': hash,
        'versionCode': versionCode,
      }) ??
      'opened';
}

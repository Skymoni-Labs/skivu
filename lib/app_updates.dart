import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'app_platform.dart';
import 'update_files.dart';

class AppRelease {
  const AppRelease({
    required this.version,
    required this.versionCode,
    required this.minSdk,
    required this.abi,
    required this.url,
    required this.hash,
    required this.size,
    required this.notes,
    required this.packageName,
    required this.signerSha256,
  });
  final String version, abi, hash, notes, packageName, signerSha256;
  final Uri url;
  final int versionCode, minSdk, size;

  factory AppRelease.parse(Map raw, AppDeviceInfo device, String abi) {
    final url = Uri.parse(raw['download_url'] as String);
    final hash = (raw['sha256'] as String).toLowerCase();
    final signer = (raw['signer_sha256'] as String).toLowerCase().replaceAll(
      ':',
      '',
    );
    final size = (raw['size'] as num).toInt();
    final versionCode = (raw['version_code'] as num).toInt();
    final minSdk = (raw['min_sdk'] as num).toInt();
    final segments = url.pathSegments;
    if (url.scheme != 'https' ||
        url.host != 'skymoni.com' ||
        url.userInfo.isNotEmpty ||
        (url.hasPort && url.port != 443) ||
        url.hasFragment ||
        url.hasQuery ||
        segments.length != 5 ||
        segments[0] != 'api' ||
        segments[1] != 'app-update' ||
        segments[2] != 'download' ||
        !RegExp(r'^[A-Za-z0-9._+\-]{1,120}$').hasMatch(segments[3]) ||
        ['.', '..'].contains(segments[3]) ||
        segments[4] != abi ||
        raw['abi'] != abi ||
        raw['package_name'] != device.packageName ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash) ||
        signer != device.signerSha256.toLowerCase().replaceAll(':', '') ||
        versionCode <= device.versionCode ||
        minSdk < 21 ||
        minSdk > device.sdk ||
        size <= 0 ||
        size > 262144000) {
      throw const FormatException('更新信息不适用于当前安装版本。');
    }
    return AppRelease(
      version: raw['version'] as String,
      versionCode: versionCode,
      minSdk: minSdk,
      abi: abi,
      url: url,
      hash: hash,
      size: size,
      notes: (raw['notes'] as String? ?? '').substring(
        0,
        (raw['notes'] as String? ?? '').length.clamp(0, 5000),
      ),
      packageName: raw['package_name'] as String,
      signerSha256: signer,
    );
  }
}

typedef UpdateWriter =
    Future<String> Function(
      Stream<List<int>> stream, {
      required String path,
      required int size,
      required String hash,
      required void Function(int) progress,
      required bool Function() cancelled,
    });

class AppUpdates extends ChangeNotifier {
  AppUpdates({
    AppPlatform? platform,
    http.Client Function()? clientFactory,
    UpdateWriter? writer,
  }) : platform = platform ?? AppPlatform(),
       _clients = clientFactory ?? http.Client.new,
       _writer = writer ?? saveUpdate;
  final AppPlatform platform;
  final http.Client Function() _clients;
  final UpdateWriter _writer;
  AppDeviceInfo? device;
  AppRelease? release;
  String? error, downloadedPath, message;
  bool checking = false, downloading = false, installing = false;
  int downloadedBytes = 0;
  http.Client? _downloadClient;
  Completer<void>? _abort;
  bool _cancelled = false, _disposed = false;
  bool get supported => platform.supported;
  double get progress => release == null ? 0 : downloadedBytes / release!.size;
  void changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> check({bool silent = false}) async {
    if (!supported || checking || downloading || installing) return;
    checking = true;
    if (!silent) {
      error = null;
      message = null;
    }
    changed();
    final client = _clients();
    try {
      final info = await platform.info();
      device = info;
      final abi = info.abis
          .where((a) => ['arm64-v8a', 'x86_64'].contains(a))
          .firstOrNull;
      if (abi == null) throw const FormatException('暂无适配当前设备的安装包。');
      final request = http.Request(
        'GET',
        Uri.https('skymoni.com', '/api/app-update/latest', {
          'platform': 'android',
          'abi': abi,
          'version_code': '${info.versionCode}',
        }),
      )..followRedirects = false;
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200)
        throw const FormatException('更新服务暂不可用，请稍后重试。');
      final bytes = <int>[];
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 20),
      )) {
        if (bytes.length + chunk.length > 65536)
          throw const FormatException('更新信息异常。');
        bytes.addAll(chunk);
      }
      final raw = jsonDecode(utf8.decode(bytes)) as Map;
      if (raw['success'] != true || raw['data'] is! Map)
        throw const FormatException('更新信息异常。');
      final data = raw['data'] as Map;
      if (data['available'] is! bool) throw const FormatException('更新信息异常。');
      if (data['available'] != true) {
        release = null;
        downloadedPath = null;
        message = '当前已是最新版本';
      } else {
        final next = AppRelease.parse(data, info, abi);
        if (next.hash != release?.hash ||
            next.versionCode != release?.versionCode) {
          downloadedPath = null;
          downloadedBytes = 0;
        }
        release = next;
        error = null;
        message = info.installMessage;
      }
    } on FormatException catch (e) {
      if (!silent) error = e.message;
    } catch (_) {
      if (!silent) error = '无法检查更新，请检查网络后重试。';
    } finally {
      client.close();
      checking = false;
      changed();
    }
  }

  Future<void> download() async {
    final candidate = release;
    if (candidate == null || downloading || checking || installing) return;
    downloading = true;
    downloadedBytes = 0;
    downloadedPath = null;
    error = null;
    message = null;
    _cancelled = false;
    final client = _clients();
    _downloadClient = client;
    final abort = Completer<void>();
    _abort = abort;
    changed();
    try {
      final path = await platform.prepareUpdate(
        versionCode: candidate.versionCode,
        hash: candidate.hash,
      );
      if (_cancelled) return;
      final request = http.AbortableRequest(
        'GET',
        candidate.url,
        abortTrigger: abort.future,
      )..followRedirects = false;
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200 ||
          (response.contentLength != null &&
              response.contentLength != candidate.size))
        throw const FormatException('更新包未能完整下载，请稍后重试。');
      var lastProgress = DateTime.now();
      downloadedPath = await _writer(
        response.stream.timeout(const Duration(seconds: 30)),
        path: path,
        size: candidate.size,
        hash: candidate.hash,
        cancelled: () => _cancelled,
        progress: (bytes) {
          downloadedBytes = bytes;
          if (DateTime.now().difference(lastProgress).inMilliseconds > 100) {
            lastProgress = DateTime.now();
            changed();
          }
        },
      );
      message = '下载已校验，可继续安装';
    } on FormatException catch (e) {
      if (!_cancelled) error = e.message;
    } catch (_) {
      if (!_cancelled) error = '下载未完成，请检查网络后重试。';
    } finally {
      client.close();
      _downloadClient = null;
      _abort = null;
      downloading = false;
      changed();
    }
  }

  void cancelDownload() {
    _cancelled = true;
    if (_abort?.isCompleted == false) _abort!.complete();
    _downloadClient?.close();
    message = '已取消下载';
    changed();
  }

  Future<void> install() async {
    final path = downloadedPath;
    final candidate = release;
    if (path == null ||
        candidate == null ||
        installing ||
        downloading ||
        checking)
      return;
    installing = true;
    error = null;
    changed();
    try {
      final result = await platform.installUpdate(
        path,
        candidate.hash,
        candidate.versionCode,
      );
      message = result == 'permission_required'
          ? '请允许 Skivu 安装更新，返回后再次点击“安装更新”。'
          : '请在安卓系统页面确认安装';
    } catch (_) {
      error = '安装验证未通过，请重新下载，或确认安装包与当前版本签名一致。';
      downloadedPath = null;
      downloadedBytes = 0;
    } finally {
      installing = false;
      changed();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    cancelDownload();
    super.dispose();
  }
}

final appUpdates = AppUpdates();

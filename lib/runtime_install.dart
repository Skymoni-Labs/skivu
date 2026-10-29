import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'app_platform.dart';
import 'app_updates.dart' show UpdateWriter;
import 'update_files.dart';

class RuntimeRelease {
  RuntimeRelease(this.data, this.url);
  final Map<String, dynamic> data;
  final Uri url;
  int get size => data['size'] as int;
  int get versionCode => data['version_code'] as int;
  String get version => data['version'] as String;
  String get hash => data['sha256'] as String;
  String get abi => data['abi'] as String;
  String get notes => data['notes'] as String;
  static RuntimeRelease parse(
    Map raw,
    Map device,
    String component,
    String signer,
    String abi,
  ) {
    final url = Uri.parse(raw['download_url'] as String),
        parts = url.pathSegments;
    final package = component.split('/').first;
    if (url.scheme != 'https' ||
        url.host != 'skymoni.com' ||
        url.userInfo.isNotEmpty ||
        (url.hasPort && url.port != 443) ||
        url.hasQuery ||
        url.hasFragment ||
        parts.length != 6 ||
        parts.take(3).join('/') != 'api/app-runtime/download' ||
        parts[3] != package ||
        parts[4] != raw['id'] ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(parts[4]) ||
        parts[5] != abi ||
        raw['abi'] != abi ||
        raw['component'] != component ||
        raw['package_name'] != package ||
        raw['signer_sha256'] != signer ||
        raw['size'] is! int ||
        raw['size'] <= 0 ||
        raw['size'] > 512 * 1024 * 1024 ||
        raw['version_code'] is! int ||
        raw['version_code'] <= 0 ||
        raw['min_sdk'] is! int ||
        raw['min_sdk'] < 26 ||
        raw['min_sdk'] > device['sdk'] ||
        raw['sha256'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(raw['sha256']) ||
        raw['version'] is! String ||
        raw['version'].length > 60 ||
        raw['notes'] is! String ||
        raw['notes'].length > 4000) {
      throw const FormatException('运行组件信息不适用于此设备或来源未通过校验。');
    }
    return RuntimeRelease(Map<String, dynamic>.from(raw), url);
  }
}

class RuntimeInstall extends ChangeNotifier {
  RuntimeInstall({
    required this.component,
    required this.signer,
    AppPlatform? platform,
    http.Client Function()? clients,
    UpdateWriter? writer,
    required this.checkGrant,
  }) : platform = platform ?? AppPlatform(),
       clients = clients ?? http.Client.new,
       writer = writer ?? saveUpdate;
  final String component, signer;
  final AppPlatform platform;
  final http.Client Function() clients;
  final UpdateWriter writer;
  final void Function() checkGrant;
  RuntimeRelease? release;
  Map? device;
  String? error, message, path;
  bool checking = false,
      downloading = false,
      installing = false,
      disposed = false,
      cancelled = false;
  int received = 0;
  bool waitingForInstaller = false, _refreshingInstalled = false;
  http.Client? active;
  Completer<void>? abort;
  Map<String, dynamic> get identity => {
    'component': component,
    'signerSha256': signer,
  };
  bool get ready =>
      device?['valid'] == true &&
      release != null &&
      (device!['versionCode'] as num) >= release!.versionCode;
  void changed() {
    if (!disposed) notifyListeners();
  }

  Map<String, dynamic> metadata(RuntimeRelease r) => {
    ...identity,
    'versionCode': r.versionCode,
    'sha256': r.hash,
    'abi': r.abi,
    'size': r.size,
  };
  Future<void> check() async {
    if (checking || downloading || installing || disposed) return;
    checking = true;
    error = null;
    changed();
    final client = clients();
    active = client;
    try {
      checkGrant();
      final info = await platform.runtimeInfo(identity);
      if (disposed) return;
      device = info;
      if (info['installed'] == true && info['valid'] != true)
        throw const FormatException('已安装组件的签名或能力不匹配，请先核对来源。');
      final abi = (info['abis'] as List)
          .where((a) => a == 'arm64-v8a' || a == 'x86_64')
          .firstOrNull;
      if (abi == null || (info['sdk'] as int) < 26)
        throw const FormatException('此运行组件需要 Android 8 或更新版本及64位设备。');
      final request = http.Request(
        'GET',
        Uri.https('skymoni.com', '/api/app-runtime/latest', {
          'package': component.split('/').first,
          'abi': abi as String,
        }),
      )..followRedirects = false;
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200)
        throw const FormatException('暂时无法获取运行组件，请稍后重试。');
      final bytes = <int>[];
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 30),
      )) {
        if (bytes.length + chunk.length > 65536)
          throw const FormatException('运行组件信息异常。');
        bytes.addAll(chunk);
      }
      if (disposed) return;
      checkGrant();
      final body = jsonDecode(utf8.decode(bytes));
      if (body is! Map || body['success'] != true || body['data'] is! Map)
        throw const FormatException('运行组件信息异常。');
      final next = RuntimeRelease.parse(
        body['data'],
        info,
        component,
        signer,
        abi,
      );
      if (next.hash != release?.hash) {
        path = null;
        received = 0;
      }
      release = next;
      message = ready ? '运行组件已就绪，可返回入口打开。' : (info['message'] as String?);
    } on FormatException catch (e) {
      if (!disposed) error = e.message;
    } catch (_) {
      if (!disposed) error = '检查未完成，请检查网络和插件授权后重试。';
    } finally {
      client.close();
      active = null;
      checking = false;
      changed();
    }
  }

  Future<void> download() async {
    final r = release;
    if (r == null || checking || downloading || installing || disposed) return;
    checkGrant();
    cancelled = false;
    downloading = true;
    received = 0;
    path = null;
    error = null;
    message = null;
    changed();
    final client = clients();
    active = client;
    final pending = Completer<void>();
    abort = pending;
    try {
      final dest = await platform.prepareRuntimeInstall(metadata(r));
      if (disposed || cancelled) return;
      checkGrant();
      final request = http.AbortableRequest(
        'GET',
        r.url,
        abortTrigger: pending.future,
      )..followRedirects = false;
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 45));
      if (response.statusCode != 200 ||
          (response.contentLength != null && response.contentLength != r.size))
        throw const FormatException('下载服务暂不可用，请重试。');
      var last = DateTime.now();
      path = await writer(
        response.stream.timeout(const Duration(seconds: 90)),
        path: dest,
        size: r.size,
        hash: r.hash,
        cancelled: () => cancelled || disposed,
        progress: (n) {
          received = n;
          if (DateTime.now().difference(last).inMilliseconds > 100) {
            last = DateTime.now();
            changed();
          }
        },
      );
      if (disposed || cancelled) return;
      checkGrant();
      message = '下载和完整性校验完成，可安装运行组件。';
    } on FormatException catch (e) {
      if (!cancelled && !disposed) error = e.message;
    } catch (_) {
      if (!cancelled && !disposed) error = '下载未完成，请检查网络后重试。';
    } finally {
      client.close();
      active = null;
      abort = null;
      downloading = false;
      changed();
    }
  }

  void cancel() {
    cancelled = true;
    if (abort?.isCompleted == false) abort!.complete();
    active?.close();
    message = '已取消下载';
    changed();
  }

  Future<void> install() async {
    final r = release, p = path;
    if (r == null ||
        p == null ||
        checking ||
        downloading ||
        installing ||
        disposed)
      return;
    installing = true;
    error = null;
    changed();
    try {
      checkGrant();
      final result = await platform.installRuntime({...metadata(r), 'path': p});
      if (disposed) return;
      waitingForInstaller = true;
      message = result == 'permission_required'
          ? '请允许 Skivu 安装应用，返回后再次点击安装。'
          : '请在安卓系统页面确认安装；返回后会自动检查。';
    } catch (_) {
      if (!disposed) {
        error = '安装校验未通过，请重新下载或核对系统安装权限。';
        path = null;
      }
    } finally {
      installing = false;
      changed();
    }
  }

  @override
  void dispose() {
    disposed = true;
    cancel();
    super.dispose();
  }

  Future<void> refreshInstalled() async {
    if (disposed ||
        checking ||
        downloading ||
        installing ||
        _refreshingInstalled)
      return;
    _refreshingInstalled = true;
    try {
      checkGrant();
      final info = await platform.runtimeInfo(identity);
      if (disposed) return;
      checkGrant();
      device = info;
      if (ready) {
        waitingForInstaller = false;
        message = '运行组件已就绪，可返回入口打开。';
      } else if ((info['message'] as String?)?.isNotEmpty == true) {
        message = info['message'] as String;
      }
      changed();
    } catch (_) {
    } finally {
      _refreshingInstalled = false;
    }
  }
}

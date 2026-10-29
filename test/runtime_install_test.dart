import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ski/app_platform.dart';
import 'package:ski/runtime_install.dart';

const component = 'org.example.runtime/org.example.runtime.Service';
final signer = 'a' * 64;
final fixture = utf8.encode('fixture, never installed as an Android package');
final device = {
  'installed': false,
  'valid': false,
  'versionCode': 0,
  'sdk': 36,
  'abis': ['x86_64'],
  'message': '',
};
Map<String, dynamic> metadata() => {
  'id': 'v1',
  'version': '1.0.0',
  'version_code': 1,
  'package_name': 'org.example.runtime',
  'component': component,
  'signer_sha256': signer,
  'min_sdk': 26,
  'abi': 'x86_64',
  'sha256': sha256.convert(fixture).toString(),
  'size': fixture.length,
  'notes': 'fixture',
  'download_url':
      'https://skymoni.com/api/app-runtime/download/org.example.runtime/v1/x86_64',
};

class InstallerPlatform extends AppPlatform {
  InstallerPlatform(this.path);
  final String path;
  int calls = 0;
  bool installed = false;
  @override
  Future<Map> runtimeInfo(Map<String, dynamic> identity) async => installed
      ? {...device, 'installed': true, 'valid': true, 'versionCode': 1}
      : device;
  @override
  Future<String> prepareRuntimeInstall(Map<String, dynamic> metadata) async =>
      path;
  @override
  Future<String> installRuntime(Map<String, dynamic> metadata) async {
    calls++;
    return 'permission_required';
  }
}

void main() {
  test(
    'late system installation is detected locally without another network request',
    () async {
      final platform = InstallerPlatform('/unused');
      var requests = 0;
      final model = RuntimeInstall(
        component: component,
        signer: signer,
        platform: platform,
        checkGrant: () {},
        clients: () => MockClient((_) async {
          requests++;
          return http.Response(
            jsonEncode({'success': true, 'data': metadata()}),
            200,
          );
        }),
      );
      addTearDown(model.dispose);
      await model.check();
      expect(model.ready, isFalse);
      model.waitingForInstaller = true;
      platform.installed = true;
      await model.refreshInstalled();
      expect(model.ready, isTrue);
      expect(model.waitingForInstaller, isFalse);
      expect(requests, 1);
    },
  );
  test(
    'runtime package metadata refuses external URLs and mismatched identity or architecture',
    () {
      RuntimeRelease.parse(metadata(), device, component, signer, 'x86_64');
      for (final change in [
        {'download_url': 'https://github.com/owner/repo/a.apk'},
        {
          'download_url':
              'https://skymoni.com/api/app-runtime/download/org.other/v1/x86_64',
        },
        {
          'download_url':
              'https://skymoni.com/api/app-runtime/download/org.example.runtime/v1/x86_64?url=http://private',
        },
        {'signer_sha256': 'b' * 64},
        {'component': 'org.other/org.other.Service'},
        {'abi': 'arm64-v8a'},
        {'size': 513 * 1024 * 1024},
        {'min_sdk': 100},
      ]) {
        expect(
          () => RuntimeRelease.parse(
            {...metadata(), ...change},
            device,
            component,
            signer,
            'x86_64',
          ),
          throwsFormatException,
        );
      }
    },
  );
  test(
    'only verified bytes can reach native installation and revoked grants stop install',
    () async {
      final folder = await Directory.systemTemp.createTemp('runtime-install-');
      addTearDown(() => folder.delete(recursive: true));
      final platform = InstallerPlatform('${folder.path}/runtime.apk');
      var allowed = true;
      final model = RuntimeInstall(
        component: component,
        signer: signer,
        platform: platform,
        checkGrant: () {
          if (!allowed) throw StateError('revoked');
        },
        clients: () => MockClient((request) async {
          expect(request.url.host, 'skymoni.com');
          expect(request.followRedirects, isFalse);
          return request.url.path.endsWith('latest')
              ? http.Response(
                  jsonEncode({'success': true, 'data': metadata()}),
                  200,
                )
              : http.Response.bytes(fixture, 200);
        }),
      );
      addTearDown(model.dispose);
      await model.check();
      await model.download();
      expect(model.path, isNotNull);
      expect(await File(model.path!).readAsBytes(), fixture);
      await model.install();
      expect(platform.calls, 1);
      expect(model.message, contains('允许 Skivu'));
      allowed = false;
      await model.install();
      expect(platform.calls, 1);
      expect(model.path, isNull);
    },
  );
  test('corrupt downloads are removed and cannot be installed', () async {
    final folder = await Directory.systemTemp.createTemp('runtime-corrupt-');
    addTearDown(() => folder.delete(recursive: true));
    final platform = InstallerPlatform('${folder.path}/runtime.apk');
    final model = RuntimeInstall(
      component: component,
      signer: signer,
      platform: platform,
      checkGrant: () {},
      clients: () => MockClient(
        (request) async => request.url.path.endsWith('latest')
            ? http.Response(
                jsonEncode({'success': true, 'data': metadata()}),
                200,
              )
            : http.Response.bytes(List.filled(fixture.length, 0), 200),
      ),
    );
    addTearDown(model.dispose);
    await model.check();
    await model.download();
    expect(model.path, isNull);
    expect(model.error, contains('校验失败'));
    expect(await File('${platform.path}.part').exists(), isFalse);
    await model.install();
    expect(platform.calls, 0);
  });
  test(
    'disposal aborts an in-flight download without publishing a partial APK',
    () async {
      final folder = await Directory.systemTemp.createTemp('runtime-cancel-');
      addTearDown(() => folder.delete(recursive: true));
      final stream = StreamController<List<int>>();
      final started = Completer<void>();
      final platform = InstallerPlatform('${folder.path}/runtime.apk');
      final model = RuntimeInstall(
        component: component,
        signer: signer,
        platform: platform,
        checkGrant: () {},
        clients: () => MockClient.streaming((request, _) async {
          if (request.url.path.endsWith('latest'))
            return http.StreamedResponse(
              Stream.value(
                utf8.encode(jsonEncode({'success': true, 'data': metadata()})),
              ),
              200,
            );
          started.complete();
          return http.StreamedResponse(
            stream.stream,
            200,
            contentLength: fixture.length,
          );
        }),
      );
      await model.check();
      final download = model.download();
      await started.future;
      model.dispose();
      stream.add(fixture);
      await stream.close();
      await download;
      expect(model.path, isNull);
      expect(platform.calls, 0);
      expect(await File(platform.path).exists(), isFalse);
    },
  );
}

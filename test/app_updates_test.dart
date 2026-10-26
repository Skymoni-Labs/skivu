import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ski/app_platform.dart';
import 'package:ski/app_updates.dart';
import 'package:ski/update_files_io.dart';

const signer =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const device = AppDeviceInfo(
  version: '0.1.0',
  versionCode: 2,
  packageName: 'com.skyjjgw.independent.ski',
  sdk: 36,
  abis: ['arm64-v8a'],
  signerSha256: signer,
);
final bytes = utf8.encode('fixture APK bytes; no executable content');
String get fixturePath =>
    '/fixture/Skivu-3-${sha256.convert(bytes).toString().substring(0, 16)}.apk';
Map<String, dynamic> release() => {
  'available': true,
  'version': '0.1.1',
  'version_code': 3,
  'min_sdk': 24,
  'abi': 'arm64-v8a',
  'size': bytes.length,
  'download_url':
      'https://skymoni.com/api/app-update/download/v0.1.1/arm64-v8a',
  'sha256': sha256.convert(bytes).toString(),
  'package_name': device.packageName,
  'signer_sha256': signer,
  'notes': 'A fixture release',
};
http.Response manifest(Map data) =>
    http.Response(jsonEncode({'success': true, 'data': data}), 200);

class UpdatePlatform extends AppPlatform {
  int installs = 0;
  bool failInstall = false;
  final location = Completer<String>();
  bool delayPath = false;
  @override
  bool get supported => true;
  @override
  Future<AppDeviceInfo> info() async => device;
  @override
  Future<String> prepareUpdate({
    required int versionCode,
    required String hash,
  }) async {
    expect(versionCode, 3);
    expect(hash, sha256.convert(bytes).toString());
    return delayPath ? location.future : fixturePath;
  }

  @override
  Future<String> installUpdate(
    String path,
    String hash,
    int versionCode,
  ) async {
    if (failInstall) throw StateError('fixture installer failure');
    expect(path, fixturePath);
    expect(hash, sha256.convert(bytes).toString());
    expect(versionCode, 3);
    installs++;
    return installs == 1 ? 'permission_required' : 'opened';
  }
}

class PreviewUpdatePlatform extends UpdatePlatform {
  @override
  Future<AppDeviceInfo> info() async => const AppDeviceInfo(
    version: '0.2.42',
    versionCode: 46,
    packageName: 'com.skyjjgw.independent.ski.devicepreview',
    sdk: 36,
    abis: ['x86_64'],
    signerSha256: signer,
  );
}

Future<String> memoryWriter(
  Stream<List<int>> stream, {
  required String path,
  required int size,
  required String hash,
  required void Function(int) progress,
  required bool Function() cancelled,
}) async {
  final received = <int>[];
  await for (final chunk in stream) {
    if (cancelled()) throw StateError('cancelled');
    received.addAll(chunk);
    progress(received.length);
  }
  if (received.length != size || sha256.convert(received).toString() != hash)
    throw const FormatException('更新包校验失败');
  return path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'separate preview builds never contact or install from the production update channel',
    () async {
      var requests = 0;
      final updates = AppUpdates(
        platform: PreviewUpdatePlatform(),
        clientFactory: () => MockClient((request) async {
          requests++;
          return manifest(release());
        }),
      );
      await updates.check();
      expect(requests, 0);
      expect(updates.release, isNull);
      expect(updates.message, contains('独立构建'));
    },
  );
  test(
    'native preparation receives the release identity for separate APK paths',
    () async {
      const channel = MethodChannel('skivu/app_platform');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final requested = <Map>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'prepareUpdate');
        final args = call.arguments as Map;
        requested.add(args);
        return '/cache/updates/Skivu-${args['versionCode']}-${(args['sha256'] as String).substring(0, 16)}.apk';
      });
      final platform = AppPlatform();
      final first = await platform.prepareUpdate(
        versionCode: 18,
        hash: 'a' * 64,
      );
      final second = await platform.prepareUpdate(
        versionCode: 19,
        hash: 'b' * 64,
      );
      expect(first, isNot(second));
      expect(requested, [
        {'versionCode': 18, 'sha256': 'a' * 64},
        {'versionCode': 19, 'sha256': 'b' * 64},
      ]);
    },
  );
  test(
    'release metadata rejects host, signer, downgrade, SDK, ABI and package mismatch',
    () {
      expect(AppRelease.parse(release(), device, 'arm64-v8a').versionCode, 3);
      for (final patch in [
        {'download_url': 'https://github.com/any/file.apk'},
        {
          'download_url':
              'http://skymoni.com/api/app-update/download/v1/arm64-v8a',
        },
        {
          'download_url':
              'https://skymoni.com/api/app-update/download/v1/arm64-v8a?key=secret',
        },
        {
          'download_url':
              'https://skymoni.com/api/app-update/download/../arm64-v8a',
        },
        {
          'signer_sha256':
              'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        },
        {'version_code': 2},
        {'min_sdk': 40},
        {'abi': 'x86_64'},
        {'package_name': 'different.app'},
        {'size': 300000000},
        {'sha256': 'bad'},
      ]) {
        expect(
          () => AppRelease.parse({...release(), ...patch}, device, 'arm64-v8a'),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'checks same-origin metadata and only installs a fully validated download',
    () async {
      final platform = UpdatePlatform();
      final requests = <http.Request>[];
      final updates = AppUpdates(
        platform: platform,
        writer: memoryWriter,
        clientFactory: () => MockClient((r) async {
          requests.add(r);
          expect(r.followRedirects, isFalse);
          expect(r.headers['Authorization'], isNull);
          if (r.url.path.endsWith('/latest')) {
            expect(r.url.queryParameters, {
              'platform': 'android',
              'abi': 'arm64-v8a',
              'version_code': '2',
            });
            return manifest(release());
          }
          expect(r.url.path, '/api/app-update/download/v0.1.1/arm64-v8a');
          return http.Response.bytes(bytes, 200);
        }),
      );
      await updates.check();
      await updates.install();
      expect(platform.installs, 0);
      await updates.download();
      expect(updates.downloadedBytes, bytes.length);
      expect(updates.downloadedPath, isNotNull);
      await updates.install();
      expect(updates.message, contains('允许'));
      await updates.install();
      expect(platform.installs, 2);
      expect(updates.message, contains('安卓系统'));
      expect(requests.length, 2);
      updates.dispose();
    },
  );

  test(
    'installer verification failure permits a clean retry download',
    () async {
      final platform = UpdatePlatform()..failInstall = true;
      final updates = AppUpdates(
        platform: platform,
        writer: memoryWriter,
        clientFactory: () => MockClient(
          (r) async => r.url.path.endsWith('/latest')
              ? manifest(release())
              : http.Response.bytes(bytes, 200),
        ),
      );
      await updates.check();
      await updates.download();
      await updates.install();
      expect(updates.error, isNotNull);
      expect(updates.downloadedPath, isNull);
      platform.failInstall = false;
      await updates.download();
      await updates.install();
      expect(updates.error, isNull);
      expect(platform.installs, 1);
      updates.dispose();
    },
  );

  test('truncated or corrupted downloads never become installable', () async {
    for (final data in [bytes.sublist(0, 8), List.filled(bytes.length, 0)]) {
      final platform = UpdatePlatform();
      final updates = AppUpdates(
        platform: platform,
        writer: memoryWriter,
        clientFactory: () => MockClient(
          (r) async => r.url.path.endsWith('/latest')
              ? manifest(release())
              : http.Response.bytes(data, 200),
        ),
      );
      await updates.check();
      await updates.download();
      await updates.install();
      expect(updates.downloadedPath, isNull);
      expect(platform.installs, 0);
      expect(updates.error, isNotNull);
      updates.dispose();
    }
  });

  test(
    'cancel before the download request avoids network and installer side effects',
    () async {
      final platform = UpdatePlatform()..delayPath = true;
      var downloads = 0;
      final updates = AppUpdates(
        platform: platform,
        writer: memoryWriter,
        clientFactory: () => MockClient((r) async {
          if (r.url.path.endsWith('/latest')) return manifest(release());
          downloads++;
          return http.Response.bytes(bytes, 200);
        }),
      );
      await updates.check();
      final download = updates.download();
      updates.cancelDownload();
      platform.location.complete(fixturePath);
      await download;
      expect(downloads, 0);
      expect(updates.downloadedPath, isNull);
      expect(updates.downloading, isFalse);
      updates.dispose();
    },
  );

  test(
    'no-release and failed metadata do not invent an available update',
    () async {
      final updates = AppUpdates(
        platform: UpdatePlatform(),
        clientFactory: () =>
            MockClient((r) async => manifest({'available': false})),
      );
      await updates.check();
      expect(updates.release, isNull);
      expect(updates.message, contains('最新'));
      updates.dispose();
      final malformed = AppUpdates(
        platform: UpdatePlatform(),
        clientFactory: () => MockClient((r) async => manifest({})),
      );
      await malformed.check();
      expect(malformed.release, isNull);
      expect(malformed.error, isNotNull);
      malformed.dispose();
    },
  );

  test(
    'streamed file writer commits only the expected bytes/hash and removes partial failures',
    () async {
      final root = Directory(
        'D:/CodexBuilds/ski-independent-ui/update-file-tests',
      )..createSync(recursive: true);
      final directory = root.createTempSync('writer-');
      final path = '${directory.path}/Skivu-update.apk';
      try {
        await saveUpdate(
          Stream.fromIterable([bytes.sublist(0, 4), bytes.sublist(4)]),
          path: path,
          size: bytes.length,
          hash: sha256.convert(bytes).toString(),
          progress: (_) {},
          cancelled: () => false,
        );
        expect(await File(path).readAsBytes(), bytes);
        await expectLater(
          saveUpdate(
            Stream.value([1, 2, 3]),
            path: path,
            size: 3,
            hash: sha256.convert(bytes).toString(),
            progress: (_) {},
            cancelled: () => false,
          ),
          throwsFormatException,
        );
        expect(File('$path.part').existsSync(), isFalse);
        expect(await File(path).readAsBytes(), bytes);
        await expectLater(
          saveUpdate(
            Stream.value(bytes),
            path: path,
            size: bytes.length,
            hash: sha256.convert(bytes).toString(),
            progress: (_) {},
            cancelled: () => true,
          ),
          throwsStateError,
        );
        expect(File('$path.part').existsSync(), isFalse);
      } finally {
        // Only known, nonrecursive fixture paths within this test's directory.
        for (final name in ['Skivu-update.apk', 'Skivu-update.apk.part']) {
          final file = File('${directory.path}/$name');
          if (file.existsSync()) file.deleteSync();
        }
        directory.deleteSync();
      }
    },
  );
}

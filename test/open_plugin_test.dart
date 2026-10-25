import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ski/open_plugin.dart';
import 'package:ski/open_plugin_bridge.dart';
import 'package:ski/open_plugin_network.dart';
import 'package:ski/chat_api.dart';
import 'package:ski/state.dart';
import 'real_chat_store_test.dart' show MemoryChats, TestModels;

class TestPaths extends PathProviderPlatform {
  TestPaths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

Map<String, dynamic> manifest({
  String id = 'test.free-plugin',
  List<String> permissions = const ['storage'],
  String version = '1.0.0',
}) => {
  'schemaVersion': 1,
  'apiVersion': '1.0',
  'id': id,
  'name': 'Example',
  'version': version,
  'minHostVersion': '0.2.38',
  'author': 'Author',
  'description': 'Independent example',
  'license': 'MIT',
  'source': 'https://github.com/example/plugin',
  'entry': 'index.html',
  'permissions': permissions,
  'networkDomains': permissions.contains('network') ? ['example.com'] : [],
  'contributes': {
    'launcher': true,
    'chatActions': [
      {'id': 'example', 'title': 'Example'},
    ],
    'chatSurface': true,
  },
};
OpenPluginPackage package({
  String id = 'test.free-plugin',
  List<String> permissions = const ['storage'],
  String version = '1.0.0',
}) => OpenPluginPackage.parse(
  jsonEncode({
    'manifest': manifest(id: id, permissions: permissions, version: version),
    'files': {
      'index.html': {
        'mime': 'text/html',
        'base64': base64Encode(utf8.encode('<h1>Freely authored</h1>')),
      },
    },
    'licenseText': 'Example test license',
    'notices': 'Test fixture',
  }),
);
Future<Map<String, dynamic>> call(
  OpenPluginBridge b,
  String method, [
  Map<String, dynamic> params = const {},
]) => b.dispatch({'id': '1', 'method': method, 'params': params});

void main() {
  test('one future or malformed catalog entry cannot hide valid plugins', () {
    final valid = {
      'manifest': manifest(),
      'url': 'https://example.com/plugin.json',
      'sha256': 'a' * 64,
      'bytes': 100,
    };
    final future = jsonDecode(jsonEncode(valid)) as Map<String, dynamic>;
    future['manifest']['permissions'] = ['future.permission'];
    future['manifest']['minHostVersion'] = '99.0.0';
    final result = parseOpenPluginCatalog({
      'schemaVersion': 1,
      'protocolVersion': '3.0',
      'packages': [
        future,
        valid,
        {'invalid': true},
      ],
    }, defaultOpenPluginCatalog);
    expect(result.entries.length, 1);
    expect(result.skipped, 2);
    expect(result.entries.values.single['catalog'], defaultOpenPluginCatalog);
  });
  test('malformed catalog headers remain rejected', () {
    expect(
      () => parseOpenPluginCatalog({
        'schemaVersion': 1,
        'protocolVersion': 'unknown',
        'packages': [],
      }, defaultOpenPluginCatalog),
      throwsFormatException,
    );
  });
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late OpenPluginRegistry registry;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('skivu-open-plugin-test-');
    PathProviderPlatform.instance = TestPaths(temp.path);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({
      'host-admin-test-key': 'host-only-fixture',
    });
    registry = OpenPluginRegistry();
    await registry.restore();
  });
  tearDown(() async {
    await temp.delete(recursive: true);
    registry.dispose();
  });
  test(
    'official catalog migration keeps third-party directories and installed data',
    () async {
      SharedPreferences.setMockInitialValues({
        'skivu.open-plugin.catalogs': [
          legacyOpenPluginCatalog,
          'https://example.com/custom.json',
          defaultOpenPluginCatalog,
        ],
      });
      await registry.restore();
      expect(registry.catalogs, [
        defaultOpenPluginCatalog,
        'https://example.com/custom.json',
      ]);
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getStringList('skivu.open-plugin.catalogs'),
        registry.catalogs,
      );
    },
  );
  Future<OpenPluginBridge> bridge({
    String id = 'test.free-plugin',
    List<String> permissions = const ['storage'],
    PluginHostCall? host,
  }) async {
    await registry.install(package(id: id, permissions: permissions));
    await registry.setEnabled(id, true);
    final b = OpenPluginBridge(
      registry: registry,
      record: registry.records[id]!,
      host: host ?? ((m, p) async => {'opaque': true}),
    );
    addTearDown(b.close);
    return b;
  }

  test(
    'arbitrary IDs, sources, resources and chat contributions are accepted',
    () {
      final p = package(id: 'org.any-author.custom-tool');
      expect(p.manifest.chatSurface, true);
      expect(p.manifest.chatActions.single['id'], 'example');
      expect(p.files.keys, ['index.html']);
    },
  );
  test(
    'path traversal and missing permissions are rejected before installation',
    () {
      for (final path in [
        '../private',
        '/absolute',
        'a//b',
        'a/../b',
        r'C:\private',
        'a\u0000b',
      ])
        expect(pluginRelativePath(path), false);
      expect(pluginRelativePath('.resources/data.json'), true);
      final m = manifest();
      m['permissions'] = ['server.admin'];
      expect(() => OpenPluginManifest.parse(m), throwsFormatException);
    },
  );
  test('package cannot replace the host SDK or omit its HTML entry', () {
    final raw = jsonDecode(package().raw);
    raw['files']['skivu-sdk.js'] = {
      'mime': 'application/javascript',
      'base64': '',
    };
    expect(
      () => OpenPluginPackage.parse(jsonEncode(raw)),
      throwsFormatException,
    );
    raw['files'] = {};
    expect(
      () => OpenPluginPackage.parse(jsonEncode(raw)),
      throwsFormatException,
    );
  });
  test(
    'install is disabled, update revokes grants, old bridges cannot continue',
    () async {
      final b = await bridge();
      expect(registry.records[b.id]!.authorized, true);
      await registry.install(package(version: '1.0.1'));
      expect(registry.records[b.id]!.enabled, false);
      expect((await call(b, 'host.info'))['error']['code'], 'CLOSED');
      await registry.setEnabled(b.id, true);
      expect(registry.records[b.id]!.authorized, true);
    },
  );
  test(
    'unsupported capabilities and undeclared permissions never reach host',
    () async {
      var hostCalls = 0;
      final b = await bridge(
        host: (m, p) async {
          hostCalls++;
          return null;
        },
      );
      expect(
        (await call(b, 'admin.login'))['error']['code'],
        'METHOD_NOT_FOUND',
      );
      expect(
        (await call(b, 'characters.get', {'roleId': 'x'}))['error']['code'],
        'PERMISSION_DENIED',
      );
      expect(hostCalls, 0);
      final info = (await call(b, 'host.info'))['result'];
      expect(jsonEncode(info), isNot(contains('host-only-fixture')));
      expect(info['methods'], isNot(contains('settings.get')));
    },
  );
  test(
    'six MiB atomic save survives restart and cannot cross plugin namespaces',
    () async {
      final a = await bridge(), b = await bridge(id: 'test.free-plugin.other');
      final value = 'x' * (6 * 1024 * 1024);
      expect(
        (await call(a, 'storage.set', {'key': 'state', 'value': value}))['ok'],
        true,
      );
      expect((await call(b, 'storage.get', {'key': 'state'}))['result'], null);
      final restored = OpenPluginRegistry();
      await restored.restore();
      expect(restored.records[a.id]!.authorized, true);
      final again = OpenPluginBridge(
        registry: restored,
        record: restored.records[a.id]!,
        host: (m, p) async => null,
      );
      expect(
        (await call(again, 'storage.get', {'key': 'state'}))['result'],
        value,
      );
      again.close();
      restored.dispose();
    },
  );
  test(
    'concurrent saves preserve both keys and closing rejects late responses',
    () async {
      final b = await bridge();
      await Future.wait([
        call(b, 'storage.set', {'key': 'a', 'value': 1}),
        call(b, 'storage.set', {'key': 'b', 'value': 2}),
      ]);
      expect(
        (await call(b, 'storage.keys'))['result'],
        unorderedEquals(['a', 'b']),
      );
      final pending = Completer<Object?>();
      final c = await bridge(id: 'test.late', host: (m, p) => pending.future);
      final result = call(c, 'context.get');
      await Future<void>.delayed(Duration.zero);
      await registry.setEnabled(c.id, false);
      pending.complete({'private': 'must not deliver'});
      expect((await result)['error']['code'], 'CLOSED');
    },
  );
  test(
    'own secrets cannot read host keys or clear a nested plugin ID',
    () async {
      final a = await bridge(permissions: ['secrets']),
          b = await bridge(
            id: 'test.free-plugin.child',
            permissions: ['secrets'],
          );
      expect(
        (await call(a, 'secrets.get', {
          'key': 'host-admin-test-key',
        }))['result'],
        null,
      );
      await call(a, 'secrets.set', {'key': 'key', 'value': 'a-test'});
      await call(b, 'secrets.set', {'key': 'key', 'value': 'b-test'});
      await clearOpenPluginSecrets(a.id);
      expect(
        (await call(b, 'secrets.get', {'key': 'key'}))['result'],
        'b-test',
      );
      expect(
        await const FlutterSecureStorage().read(key: 'host-admin-test-key'),
        'host-only-fixture',
      );
    },
  );
  test(
    'plugin filesystem cannot reach app files, uninstall keeps data by default',
    () async {
      final b = await bridge(permissions: ['files', 'storage']);
      expect(
        (await call(b, 'fs.read', {
          'path': '../package.json',
        }))['error']['code'],
        'INVALID_ARGUMENT',
      );
      await call(b, 'fs.write', {
        'path': 'docs/a.txt',
        'base64': base64Encode(utf8.encode('saved')),
      });
      expect((await call(b, 'fs.list'))['result'], ['docs/a.txt']);
      await call(b, 'storage.set', {'key': 'keep', 'value': true});
      await registry.uninstall(b.id);
      expect(await readPluginData(b.id, 'storage'), contains('keep'));
      expect(await readPluginFile(b.id, 'docs/a.txt'), utf8.encode('saved'));
      await eraseOpenPluginData(b.id);
      expect(await readPluginData(b.id, 'storage'), null);
      expect(await readPluginFile(b.id, 'docs/a.txt'), null);
    },
  );
  test(
    'prompt contribution only affects its role while enabled and authorized',
    () async {
      final b = await bridge(permissions: ['prompt']);
      await registry.setPrompt(b.id, 'r1', 'special instruction');
      expect(registry.promptFor('r1'), contains('special instruction'));
      expect(registry.promptFor('r2'), '');
      await registry.setEnabled(b.id, false);
      expect(registry.promptFor('r1'), '');
    },
  );
  test(
    'host failures are sanitized without returning credentials or debug URLs',
    () async {
      final b = await bridge(
        host: (m, p) async =>
            throw StateError('https://private.invalid token=host-only-fixture'),
      );
      final r = await call(b, 'context.get');
      expect(r['ok'], false);
      expect(jsonEncode(r), isNot(contains('host-only-fixture')));
      expect(jsonEncode(r), isNot(contains('private.invalid')));
    },
  );
  test(
    'network rejects private, first-party, credential URLs and wildcard confusion',
    () {
      for (final url in [
        'https://skymoni.com/api',
        'https://x.skymoni.com/a',
        'http://example.com',
        'https://user:pass@example.com',
        'https://127.0.0.1',
        'https://10.0.0.2',
        'https://192.168.1.1',
        'https://169.254.169.254',
        'https://198.18.0.1',
        'https://[::1]',
        'https://evilexample.com',
      ])
        expect(
          () => pluginNetworkUri(url, ['*.example.com']),
          throwsA(isA<PluginApiError>()),
        );
      expect(
        pluginNetworkUri('https://a.example.com/path', ['*.example.com']).host,
        'a.example.com',
      );
      expect(
        pluginNetworkUri('https://example.org', ['*']).host,
        'example.org',
      );
      expect(
        pluginNetworkUri('https://example.com:8443', ['example.com']).port,
        8443,
      );
      expect(
        () => pluginNetworkUri('http://127.0.0.1:8000', ['*']),
        throwsA(isA<PluginApiError>()),
      );
      expect(
        pluginNetworkUri('http://127.0.0.1:8000', ['*'], allowLocal: true).port,
        8000,
      );
      expect(
        () => pluginNetworkUri('http://skymoni.com', ['*'], allowLocal: true),
        throwsA(isA<PluginApiError>()),
      );
    },
  );
  test(
    'proxy sends only plugin headers, refuses redirects, and handles binary',
    () async {
      final requests = <http.Request>[];
      final network = PluginNetwork(
        resolve: false,
        client: MockClient((r) async {
          requests.add(r);
          return http.Response.bytes(
            [0, 1, 255],
            302,
            headers: {
              'location': 'https://skymoni.com/private',
              'set-cookie': 'fixture',
            },
          );
        }),
      );
      final r = await network.request(
        {
          'url': 'https://example.com',
          'headers': {'Authorization': 'Bearer plugin-fixture'},
          'responseType': 'base64',
        },
        ['example.com'],
      );
      expect(requests.length, 1);
      expect(requests.single.followRedirects, false);
      expect(requests.single.headers['authorization'], 'Bearer plugin-fixture');
      expect(r['base64'], base64Encode([0, 1, 255]));
      expect(r['headers']['set-cookie'], 'fixture');
      network.close();
    },
  );
  test(
    'opaque model execution uses current auth path and returns no connection config',
    () async {
      final requests = <http.Request>[];
      final store = DemoStore(
        storage: MemoryChats(),
        settings: TestModels(),
        api: ChatApi(
          clientFactory: () => MockClient((r) async {
            requests.add(r);
            return http.Response(
              jsonEncode({
                'choices': [
                  {
                    'message': {'content': 'result'},
                  },
                ],
                'usage': {'prompt_tokens': 12, 'completion_tokens': 2},
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }),
        ),
      );
      addTearDown(store.dispose);
      await store.restore();
      final session = await store.startPluginReply(
        store.role.id,
        'fixture instruction',
        [],
        128,
      );
      final events = await session.events.toList();
      expect(events.map((e) => e.text).join(), 'result');
      expect(requests.single.headers['authorization'], 'Bearer test-key-only');
      expect(
        jsonEncode(jsonDecode(requests.single.body)),
        contains('fixture instruction'),
      );
      expect(store.messages.any((m) => m.text == 'result'), false);
      session.cancel();
    },
  );
}

import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ski/extension_market.dart';
import 'package:ski/extensions_page.dart';

Map<String, dynamic> metadata({String version = '1.0.0'}) => {
  'schemaVersion': 1,
  'id': 'test.editor',
  'name': '文字编辑',
  'version': version,
  'author': 'Example',
  'license': 'MIT',
  'description': '编辑文字的指导。',
  'kind': 'skill',
  'minHostVersion': '0.2.35',
  'permissions': ['prompt'],
  'source': {
    'repository': 'https://github.com/example/editor',
    'commit': 'a' * 40,
    'path': 'skills/editor',
  },
};
String bundle({String version = '1.0.0', String instruction = '保留事实，减少重复。'}) =>
    jsonEncode({
      'metadata': metadata(version: version),
      'payload': {
        'licenseText': 'Example license',
        'instruction': instruction,
        'references': {'guide.md': '用简短而精确的句子。'},
      },
    });
ExtensionInfo entry(String raw) => ExtensionInfo.catalog({
  ...jsonDecode(raw)['metadata'],
  'package': {
    'url':
        'https://raw.githubusercontent.com/skyjjgw/skivu-plugins/${'b' * 40}/extensions/test.editor/package.json',
    'sha256': sha256.convert(utf8.encode(raw)).toString(),
    'bytes': utf8.encode(raw).length,
  },
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'install does not activate; enabling survives restart; uninstall clears prompt',
    () async {
      final raw = bundle();
      final library = ExtensionLibrary(
        client: MockClient(
          (_) async => http.Response.bytes(utf8.encode(raw), 200),
        ),
      );
      addTearDown(library.dispose);
      expect(await library.install(entry(raw)), isTrue);
      expect(library.skillPrompt, isEmpty);
      expect(await library.enableSkill('test.editor', true), isTrue);
      expect(library.skillPrompt, contains('保留事实'));
      expect(library.skillPrompt, contains('guide.md'));
      final restored = ExtensionLibrary();
      addTearDown(restored.dispose);
      await restored.restore();
      expect(restored.skillPrompt, library.skillPrompt);
      expect(await restored.uninstall('test.editor'), isTrue);
      expect(restored.skillPrompt, isEmpty);
    },
  );

  test('tampered upgrade preserves installed package and activation', () async {
    var raw = bundle();
    final library = ExtensionLibrary(
      client: MockClient(
        (_) async => http.Response.bytes(utf8.encode(raw), 200),
      ),
    );
    addTearDown(library.dispose);
    await library.install(entry(raw));
    await library.enableSkill('test.editor', true);
    final upgrade = entry(bundle(version: '2.0.0'));
    raw = bundle(version: '2.0.0', instruction: 'tampered');
    expect(await library.install(upgrade), isFalse);
    expect(library.installed['test.editor']!.version, '1.0.0');
    expect(library.enabledSkills, contains('test.editor'));
  });

  test(
    'compares metadata structurally and refuses oversized active upgrade',
    () async {
      final original = jsonDecode(bundle());
      original['metadata']['source'] = {
        'path': 'skills/editor',
        'commit': 'a' * 40,
        'repository': 'https://github.com/example/editor',
      };
      var raw = jsonEncode(original);
      final library = ExtensionLibrary(
        client: MockClient(
          (_) async => http.Response.bytes(utf8.encode(raw), 200),
        ),
      );
      addTearDown(library.dispose);
      expect(
        await library.install(entry(bundle())),
        isFalse,
        reason: 'bytes differ from catalog digest',
      );
      final catalog = ExtensionInfo.catalog({
        ...metadata(),
        'package': {
          'url': entry(raw).packageUrl.toString(),
          'sha256': entry(raw).digest,
          'bytes': entry(raw).bytes,
        },
      });
      expect(await library.install(catalog), isTrue);
      await library.enableSkill('test.editor', true);
      raw = bundle(version: '2.0.0', instruction: 'x' * maxActiveSkillBytes);
      expect(await library.install(entry(raw)), isFalse);
      expect(library.installed['test.editor']!.version, '1.0.0');
    },
  );

  test(
    'rejects foreign downloads, executable fields, unsafe reference paths and invalid permissions',
    () {
      final package = jsonDecode(bundle());
      package['payload']['scripts'] = {'run.sh': 'echo run'};
      expect(
        () => InstalledExtension.parse(jsonEncode(package)),
        throwsFormatException,
      );
      package['payload'].remove('scripts');
      package['payload']['references'] = {'../escape.md': 'escape'};
      expect(
        () => InstalledExtension.parse(jsonEncode(package)),
        throwsFormatException,
      );
      final bad = metadata()..['permissions'] = 'network';
      expect(() => ExtensionInfo.validateMetadata(bad), throwsFormatException);
      expect(
        () => ExtensionInfo.catalog({
          ...metadata(),
          'package': {
            'url': 'https://example.com/package.json',
            'sha256': 'c' * 64,
            'bytes': 200,
          },
        }),
        throwsFormatException,
      );
      expect(
        () => validateMcpEndpoint('https://user:pass@example.com/mcp'),
        throwsFormatException,
      );
      expect(
        () => validateMcpEndpoint('https://example.com/mcp?api_key=secret'),
        throwsFormatException,
      );
    },
  );

  test(
    'failed refresh retains catalog and falls back to immutable origin',
    () async {
      var available = true;
      final calls = <Uri>[];
      final raw = bundle();
      final item = {
        ...metadata(),
        'package': {
          'url': entry(raw).packageUrl.toString(),
          'sha256': entry(raw).digest,
          'bytes': entry(raw).bytes,
        },
      };
      final library = ExtensionLibrary(
        client: MockClient((request) async {
          calls.add(request.url);
          if (request.url.toString() == extensionCatalogUrl || !available)
            return http.Response('', 503);
          return http.Response(
            jsonEncode({
              'schemaVersion': 1,
              'protocolVersion': '2.0',
              'plugins': [item],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      addTearDown(library.dispose);
      await library.refresh();
      expect(library.catalog.single.id, 'test.editor');
      expect(calls.last.toString(), extensionCatalogOrigin);
      available = false;
      await library.refresh();
      expect(library.error, isNotNull);
      expect(library.catalog.single.id, 'test.editor');
    },
  );

  testWidgets('market lets user install and explicitly enable a skill', (
    tester,
  ) async {
    final raw = bundle();
    final library = ExtensionLibrary(
      client: MockClient(
        (_) async => http.Response.bytes(utf8.encode(raw), 200),
      ),
    );
    addTearDown(library.dispose);
    library.catalog = [entry(raw)];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ExtensionsPage(library: library, autoRefresh: false),
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      await tester.tap(find.text('安装'));
      for (var i = 0; i < 100 && library.workingId != null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pumpAndSettle();
    expect(find.text('已安装 1.0.0'), findsOneWidget);
    expect(library.skillPrompt, isEmpty);
    await tester.ensureVisible(find.byType(SwitchListTile));
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    expect(library.skillPrompt, contains('保留事实'));
    expect(tester.takeException(), isNull);
  });
}

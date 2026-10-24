import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ski/brand.dart' show appVersion;
import 'package:ski/plugin_market.dart';
import 'package:ski/ui_plugins.dart';
import 'package:ski/state.dart';
import 'real_chat_store_test.dart' show MemoryChats;

Map<String, dynamic> presetFixture(
  String mode, {
  String version = '1.0.0',
  String minHost = '0.2.19',
}) => {
  'schemaVersion': 1,
  'kind': 'ui-preset',
  'renderer': pluginRenderer,
  'id': 'skivu.$mode',
  'name': mode == 'qq' ? 'QQ' : '微信',
  'version': version,
  'author': 'Skivu',
  'license': 'GPL-3.0-only',
  'description': '共享角色与独立会话的界面插件。',
  'repository': 'https://github.com/skyjjgw/skivu-plugins',
  'mode': mode,
  'minHostVersion': minHost,
  'permissions': <String>[],
};
Map<String, dynamic> catalogFixture({
  String version = '1.0.0',
  String minHost = '0.2.19',
}) => {
  'schemaVersion': 2,
  'protocolVersion': '1.0',
  'runtimeReady': true,
  'plugins': [
    for (final mode in ['qq', 'wechat'])
      {
        ...presetFixture(mode, version: version, minHost: minHost),
        'package': {
          'url':
              'https://raw.githubusercontent.com/skyjjgw/skivu-plugins/${'a' * 40}/plugins/$mode/plugin.json',
          'sha256': sha256
              .convert(
                utf8.encode(
                  jsonEncode(
                    presetFixture(mode, version: version, minHost: minHost),
                  ),
                ),
              )
              .toString(),
          'bytes': utf8
              .encode(
                jsonEncode(
                  presetFixture(mode, version: version, minHost: minHost),
                ),
              )
              .length,
        },
      },
  ],
};
Future<PluginMarket> installedMarket() async {
  final market = PluginMarket(
    client: MockClient(
      (request) async => http.Response(
        jsonEncode(
          request.url.toString() == pluginCatalogUrl
              ? catalogFixture()
              : presetFixture(
                  (catalogFixture()['plugins'] as List).firstWhere(
                    (p) =>
                        (p['package'] as Map)['sha256'] + '.json' ==
                        request.url.pathSegments.last,
                  )['mode'],
                ),
        ),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      ),
    ),
  );
  await market.refresh();
  for (final item in market.catalog) {
    expect(await market.install(item), isTrue, reason: market.error);
  }
  return market;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final minimum in ['0.2.22', appVersion]) {
    test('plugins requiring $minimum install and survive restore', () async {
      final market = PluginMarket(
        client: MockClient(
          (request) async => http.Response(
            jsonEncode(
              request.url.toString() == pluginCatalogUrl
                  ? catalogFixture(minHost: minimum)
                  : presetFixture('qq', minHost: minimum),
            ),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ),
        ),
      );
      addTearDown(market.dispose);
      await market.refresh();
      final plugin = market.catalog.first;
      expect(plugin.compatible, isTrue);
      expect(await market.install(plugin), isTrue, reason: market.error);
      final restored = PluginMarket();
      addTearDown(restored.dispose);
      await restored.restore();
      expect(restored.installedFor(ChatUiMode.qq)?.minHostVersion, minimum);
      expect(restored.installedFor(ChatUiMode.qq)?.compatible, isTrue);
    });
  }
  test(
    'discover, install, restart and uninstall preserve original chats',
    () async {
      final store = DemoStore(storage: MemoryChats());
      await store.restore();
      store.newChat();
      store.messages.add(Message(true, 'PRIVATE_HISTORY'));
      final original = store.exportChats();
      final market = await installedMarket(), settings = UiPluginSettings();
      expect(market.catalog, hasLength(2));
      expect(market.installedFor(ChatUiMode.qq)?.version, '1.0.0');
      final restored = PluginMarket();
      await restored.restore();
      expect(restored.installedFor(ChatUiMode.wechat)?.version, '1.0.0');
      await settings.setEnabled(ChatUiMode.qq, true);
      expect(await market.uninstall(ChatUiMode.qq, settings), isTrue);
      expect(settings.mode, ChatUiMode.classic);
      expect(market.installedFor(ChatUiMode.qq), isNull);
      expect(market.installedFor(ChatUiMode.wechat), isNotNull);
      expect(store.exportChats(), original);
      market.dispose();
      restored.dispose();
      settings.dispose();
      store.dispose();
    },
  );
  test(
    'hash mismatch cannot replace an installed preset; offline catalog keeps it usable',
    () async {
      final original = await installedMarket();
      original.dispose();
      var offline = false;
      final market = PluginMarket(
        client: MockClient((request) async {
          if (offline) throw http.ClientException('offline');
          return http.Response(
            jsonEncode(
              request.url.toString() == pluginCatalogUrl
                  ? catalogFixture(version: '1.0.1')
                  : presetFixture('qq', version: '8.8.8'),
            ),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      await market.restore();
      await market.refresh();
      expect(await market.install(market.catalog.first), isFalse);
      expect(market.error, contains('完整性'));
      expect(market.installedFor(ChatUiMode.qq)?.version, '1.0.0');
      offline = true;
      await market.refresh();
      expect(market.error, isNotNull);
      expect(market.installedFor(ChatUiMode.wechat), isNotNull);
      market.dispose();
    },
  );
  test(
    'reject executable, extra permissions, unknown sources, duplicate IDs and incompatible versions',
    () async {
      for (final alteration in [
        (Map<String, dynamic> p) => p['permissions'] = ['network'],
        (Map<String, dynamic> p) => p['renderer'] = 'remote.script',
        (Map<String, dynamic> p) => p['script'] = 'evil.js',
        (Map<String, dynamic> p) =>
            (p['package'] as Map)['url'] = 'https://evil.test/plugin.json',
        (Map<String, dynamic> p) => (p['package'] as Map)['url'] =
            'https://raw.githubusercontent.com/skyjjgw/skivu-plugins/main/plugins/qq/plugin.json',
      ]) {
        final data = catalogFixture();
        alteration((data['plugins'] as List).first);
        expect(
          () => MarketPlugin.catalogList(jsonEncode(data)),
          throwsFormatException,
        );
      }
      final duplicate = catalogFixture();
      (duplicate['plugins'] as List).add((duplicate['plugins'] as List).first);
      expect(
        () => MarketPlugin.catalogList(jsonEncode(duplicate)),
        throwsFormatException,
      );
      final market = PluginMarket(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode(catalogFixture(minHost: '99.0.0')),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ),
        ),
      );
      await market.refresh();
      expect(market.catalog.first.compatible, isFalse);
      expect(await market.install(market.catalog.first), isFalse);
      expect(market.installedFor(ChatUiMode.qq), isNull);
      market.dispose();
    },
  );
  test(
    'domestic mirror serves catalog and package without GitHub; origin is a fallback',
    () async {
      final seen = <Uri>[];
      final market = PluginMarket(
        client: MockClient((request) async {
          seen.add(request.url);
          return http.Response(
            jsonEncode(
              request.url.toString() == pluginCatalogUrl
                  ? catalogFixture()
                  : presetFixture('qq'),
            ),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      await market.refresh();
      expect(await market.install(market.catalog.first), isTrue);
      expect(seen.every((url) => url.host == 'skymoni.com'), isTrue);
      expect(
        seen.last.path,
        '/app-plugins/packages/${market.catalog.first.digest}.json',
      );
      market.dispose();
      final fallback = PluginMarket(
        client: MockClient((request) async {
          if (request.url.host == 'skymoni.com')
            return http.Response('unavailable', 503);
          return http.Response(
            jsonEncode(
              request.url.toString() == pluginCatalogOriginUrl
                  ? catalogFixture()
                  : presetFixture('qq'),
            ),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      await fallback.refresh();
      expect(await fallback.install(fallback.catalog.first), isTrue);
      fallback.dispose();
    },
  );
}

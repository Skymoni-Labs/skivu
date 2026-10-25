import 'package:flutter_test/flutter_test.dart';
import 'dart:io';
import 'package:ski/open_plugin_dns.dart';
import 'package:ski/open_plugin_external.dart';
import 'package:ski/open_plugin_network.dart';
import 'package:ski/open_plugin_bridge.dart';

void main() {
  test('mixed DNS results cannot hide private or mapped IPv6 addresses', () {
    for (final raw in ['8.8.8.8', '2606:4700:4700::1111']) {
      expect(
        pluginExternalAddressPublic(InternetAddress(raw)),
        true,
        reason: raw,
      );
    }
    for (final raw in [
      '127.0.0.1',
      '169.254.169.254',
      '192.168.1.1',
      '::1',
      'fc00::1',
      'fe80::1',
      '::ffff:127.0.0.1',
      '2001:db8::1',
    ]) {
      expect(
        pluginExternalAddressPublic(InternetAddress(raw)),
        false,
        reason: raw,
      );
    }
  });
  test('external open has an independent declared permission', () {
    expect(pluginMethodPermissions['ui.openExternal'], 'external.open');
  });
  test(
    'only public HTTPS URLs without credentials or alternate schemes are accepted',
    () {
      expect(
        pluginExternalUri(
          'https://www.openstreetmap.org/search?query=Paris',
        ).host,
        'www.openstreetmap.org',
      );
      for (final url in [
        'javascript:alert(1)',
        'intent://test',
        'file:///etc/passwd',
        'http://example.com',
        'https://localhost/',
        'https://127.0.0.1',
        'https://169.254.169.254',
        'https://10.0.0.1',
        'https://skymoni.com',
        'https://user:password@example.com',
        'https://example.com/#javascript:foo',
        'https://example.com/\n',
      ]) {
        expect(
          () => pluginExternalUri(url),
          throwsA(isA<PluginApiError>()),
          reason: url,
        );
      }
    },
  );
  test('a private DNS target never reaches confirmation or launcher', () async {
    await expectLater(
      openPluginExternal(
        {'url': 'https://example.com'},
        check: () {},
        validateTarget: (_) async =>
            throw const PluginApiError('NETWORK_DENIED', 'test'),
        confirm: (_) async => fail('not reached'),
        launch: (_) async => fail('not reached'),
      ),
      throwsA(isA<PluginApiError>()),
    );
  });
  test('cancel produces a receipt with no external effect', () async {
    final result = await openPluginExternal(
      {'url': 'https://example.com'},
      check: () {},
      validateTarget: (_) async {},
      confirm: (_) async => false,
      launch: (_) async => fail('not reached'),
    );
    expect(result, {'status': 'cancelled'});
  });
  test('closing a plugin during confirmation blocks launch', () async {
    var closed = false;
    await expectLater(
      openPluginExternal(
        {'url': 'https://example.com'},
        check: () {
          if (closed) throw const PluginApiError('CLOSED', 'test');
        },
        validateTarget: (_) async {},
        confirm: (_) async {
          closed = true;
          return true;
        },
        launch: (_) async => fail('not reached'),
      ),
      throwsA(isA<PluginApiError>()),
    );
  });
  test(
    'accepted and no handler are separate outcomes; DNS is rechecked after consent',
    () async {
      for (final status in ['accepted', 'not_available']) {
        final events = <String>[];
        final result = await openPluginExternal(
          {'url': 'https://example.com'},
          check: () {},
          validateTarget: (_) async {
            events.add('dns');
          },
          confirm: (_) async {
            events.add('confirm');
            return true;
          },
          launch: (_) async {
            events.add('launch');
            return status;
          },
        );
        expect(result['status'], status);
        expect(events, ['dns', 'confirm', 'dns', 'launch']);
      }
    },
  );
}

// Test certificates are generated at runtime and never leave the temp directory.
import 'dart:io';
import 'dart:async';
import 'package:http/io_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/open_plugin_dns.dart';

void main() {
  late Directory temp;
  HttpServer? server;
  late File certificate;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('skivu-plugin-tls-');
    certificate = File('${temp.path}/certificate.pem');
    final config = File('${temp.path}/openssl.cnf');
    await config.writeAsString(
      '[req]\ndistinguished_name=dn\nprompt=no\nx509_extensions=extensions\n[dn]\nCN=tls-fixture.invalid\n[extensions]\nsubjectAltName=DNS:tls-fixture.invalid\nbasicConstraints=critical,CA:TRUE\n',
    );
    final result =
        await Process.run(Platform.environment['OPENSSL_BIN'] ?? 'openssl', [
          'req',
          '-x509',
          '-newkey',
          'rsa:2048',
          '-nodes',
          '-days',
          '1',
          '-keyout',
          '${temp.path}/key.pem',
          '-out',
          certificate.path,
          '-config',
          config.path,
        ]);
    if (result.exitCode != 0)
      throw StateError(
        'OpenSSL could not generate the temporary TLS test certificate',
      );
    final context = SecurityContext()
      ..useCertificateChain(certificate.path)
      ..usePrivateKey('${temp.path}/key.pem');
    server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      context,
    );
    server!.listen((request) async {
      request.response.write('TLS authenticated');
      await request.response.close();
    }, onError: (Object _) {});
  });
  tearDown(() async {
    await server?.close(force: true);
    final resolved = await temp.resolveSymbolicLinks(),
        root = await Directory.systemTemp.resolveSymbolicLinks();
    if (!resolved.startsWith(root + Platform.pathSeparator) ||
        !temp.path
            .split(Platform.pathSeparator)
            .last
            .startsWith('skivu-plugin-tls-'))
      throw StateError('Unexpected TLS test cleanup target');
    await temp.delete(recursive: true);
  });
  HttpClient client(String hostname, {required bool trust}) {
    final context = trust
        ? (SecurityContext()..setTrustedCertificates(certificate.path))
        : null;
    return HttpClient(context: context)
      ..findProxy = ((_) => 'DIRECT')
      ..connectionFactory = ((uri, proxyHost, proxyPort) =>
          pluginPinnedConnection(
            uri,
            InternetAddress.loopbackIPv4,
            securityContext: context,
          ));
  }

  test(
    'pinned HTTPS performs TLS with the original hostname instead of sending plain HTTP to port 443',
    () async {
      final http = client('tls-fixture.invalid', trust: true);
      try {
        final request = await http.getUrl(
          Uri.parse('https://tls-fixture.invalid:${server!.port}/'),
        );
        final response = await request.close();
        expect(response.statusCode, 200);
        expect(response.certificate, isNotNull);
        expect(
          await response.transform(SystemEncoding().decoder).join(),
          'TLS authenticated',
        );
      } finally {
        http.close(force: true);
      }
    },
  );
  test(
    'trusting the test CA never permits a mismatched server hostname',
    () async {
      final http = client('other.invalid', trust: true);
      try {
        await expectLater(
          http.getUrl(Uri.parse('https://other.invalid:${server!.port}/')),
          throwsA(isA<HandshakeException>()),
        );
      } finally {
        http.close(force: true);
      }
    },
  );
  test('untrusted certificates remain rejected', () async {
    final http = client('tls-fixture.invalid', trust: false);
    try {
      await expectLater(
        http.getUrl(Uri.parse('https://tls-fixture.invalid:${server!.port}/')),
        throwsA(isA<HandshakeException>()),
      );
    } finally {
      http.close(force: true);
    }
  });
  test(
    'HTTP companion still uses the pinned plain socket through IOClient',
    () async {
      final plain = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      plain.listen((request) async {
        request.response.write('local companion');
        await request.response.close();
      });
      final transport = IOClient(client('tls-fixture.invalid', trust: false));
      try {
        final response = await transport.get(
          Uri.parse('http://tls-fixture.invalid:${plain.port}/'),
        );
        expect(response.statusCode, 200);
        expect(response.body, 'local companion');
      } finally {
        transport.close();
        await plain.close(force: true);
      }
    },
  );
  test('cancelling a pending TLS handshake closes the pinned socket', () async {
    final silent = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final accepted = Completer<Socket>();
    silent.listen((socket) {
      accepted.complete(socket);
    });
    final task = await pluginPinnedConnection(
      Uri.parse('https://tls-fixture.invalid:${silent.port}/'),
      InternetAddress.loopbackIPv4,
    );
    final result = expectLater(
      task.socket.timeout(const Duration(seconds: 2)),
      throwsA(isNot(isA<TimeoutException>())),
    );
    final peer = await accepted.future;
    task.cancel();
    try {
      await result;
    } finally {
      peer.destroy();
      await silent.close();
    }
  });
}

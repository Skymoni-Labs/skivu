import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/local_runtime_page.dart';
import 'package:ski/open_plugin.dart';
import 'package:ski/open_plugin_bridge.dart';
import 'open_plugin_test.dart' as fixtures;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'runtime methods require a separately granted runtime permission',
    () async {
      final package = fixtures.package();
      final registry = OpenPluginRegistry();
      final record = OpenPluginRecord(
        package,
        enabled: true,
        grantedDigest: package.digest,
      );
      registry.records[record.manifest.id] = record;
      var calls = 0;
      final bridge = OpenPluginBridge(
        registry: registry,
        record: record,
        host: (_, __) async {
          calls++;
          return [];
        },
      );
      final result = await bridge.dispatch({
        'id': '1',
        'method': 'runtime.providers',
        'params': {},
      });
      expect((result['error'] as Map)['code'], 'PERMISSION_DENIED');
      expect(calls, 0);
      bridge.close();
      registry.dispose();
    },
  );
  testWidgets('cancelled runtime consent returns without starting a process', (
    tester,
  ) async {
    const channel = MethodChannel('skivu/local_runtime');
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final package = fixtures.package(
      permissions: ['runtime.local', 'ai.generate'],
    );
    final registry = OpenPluginRegistry();
    final record = OpenPluginRecord(
      package,
      enabled: true,
      grantedDigest: package.digest,
    );
    registry.records[record.manifest.id] = record;
    final done = Completer<Object?>();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () {
                localRuntimeCall(context, record, registry, 'runtime.open', {
                  'component':
                      'org.example.runtime/org.example.runtime.Service',
                  'signerSha256': 'a' * 64,
                }).then(done.complete);
              },
              child: const Text('launch'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('launch'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('打开本地编程环境？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await done.future;
    expect(calls, isNot(contains('start')));
    expect(find.text('launch'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    registry.dispose();
  });
}

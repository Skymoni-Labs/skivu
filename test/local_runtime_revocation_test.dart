import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ski/local_runtime_page.dart';
import 'package:ski/model_connection.dart';
import 'package:ski/open_plugin.dart';
import 'package:ski/state.dart';

import 'open_plugin_test.dart' as fixtures;

Future<Object?> runtimeMessage(String method, Map arguments) async {
  const codec = StandardMethodCodec();
  final reply = Completer<Object?>();
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        'skivu/local_runtime',
        codec.encodeMethodCall(MethodCall(method, arguments)),
        (bytes) {
          try {
            reply.complete(bytes == null ? null : codec.decodeEnvelope(bytes));
          } catch (error, stack) {
            reply.completeError(error, stack);
          }
        },
      );
  return reply.future;
}

Future<Map> runtimeFrame(int sessionId, String frame) async =>
    jsonDecode(
          await runtimeMessage('device', {
                'sessionId': sessionId,
                'frame': frame,
              })
              as String,
        )
        as Map;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const runtimeChannel = MethodChannel('skivu/local_runtime');
  const engineChannel = MethodChannel('skivu/device_engine');
  const config = ModelConnection(
    id: 'revocation-fixture',
    name: 'Fixture',
    provider: 'custom',
    protocol: ApiProtocol.chat,
    address: 'https://example.com/v1',
    model: 'fixture',
  );

  for (final uncertain in [false, true]) {
    testWidgets(
      uncertain
          ? 'plugin revocation displays uncertain cancellation without an unhandled error'
          : 'a saved model change cancels the exact active DSH request and rejects its late reply',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        FlutterSecureStorage.setMockInitialValues({});
        final originalModels = demo.models.connections.toList();
        final originalSelection = demo.models.activeId;
        demo.models.connections
          ..clear()
          ..add(config);
        demo.models.activeId = config.id;
        final registry = OpenPluginRegistry();
        final package = fixtures.package(
          permissions: ['runtime.local', 'ai.generate', 'device.shell'],
        );
        final record = OpenPluginRecord(
          package,
          enabled: true,
          grantedDigest: package.digest,
        );
        registry.records[record.manifest.id] = record;
        final startup = Completer<void>();
        final nativeResult = Completer<Map<String, dynamic>>();
        final nativeCalls = <MethodCall>[];
        final runtimeCalls = <MethodCall>[];
        int? sessionId;
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(runtimeChannel, (call) async {
          runtimeCalls.add(call);
          if (call.method == 'start') {
            sessionId = (call.arguments as Map)['sessionId'] as int;
            await startup.future;
          }
          return null;
        });
        messenger.setMockMethodCallHandler(engineChannel, (call) async {
          nativeCalls.add(call);
          if (call.method == 'invoke') return nativeResult.future;
          if (call.method == 'cancelRequest') {
            return {'outcome': uncertain ? 'unknown' : 'cancelled'};
          }
          throw StateError('Unexpected engine method ${call.method}');
        });
        addTearDown(() async {
          if (!startup.isCompleted) startup.complete();
          if (!nativeResult.isCompleted) {
            nativeResult.complete({
              'requestId': 'active_dsh_request',
              'outcome': 'cancelled',
            });
          }
          messenger.setMockMethodCallHandler(runtimeChannel, null);
          messenger.setMockMethodCallHandler(engineChannel, null);
          demo.models.connections
            ..clear()
            ..addAll(originalModels);
          demo.models.activeId = originalSelection;
          registry.dispose();
        });

        await tester.pumpWidget(
          MaterialApp(
            home: LocalRuntimePage(
              record: record,
              registry: registry,
              component: 'org.example.runtime/org.example.runtime.Service',
              signer: 'a' * 64,
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(find.text('允许本次'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(sessionId, isNotNull);
        final pending = runtimeFrame(
          sessionId!,
          jsonEncode({
            'id': '1',
            'method': 'device.engine.invoke',
            'params': {
              'tool': 'shell.execute',
              'arguments': {'command': 'sleep 500'},
              'requestId': 'active_dsh_request',
            },
          }),
        );
        await tester.pump();
        expect(
          nativeCalls.where((call) => call.method == 'invoke'),
          hasLength(1),
        );

        if (uncertain) {
          await registry.setEnabled(record.manifest.id, false);
        } else {
          await demo.models.save(
            ModelConnection.fromJson({
              ...config.toJson(),
              'streaming': !config.streaming,
            }),
            'synthetic-test-key',
          );
        }
        await tester.pump();
        startup.complete();
        nativeResult.complete({
          'requestId': 'active_dsh_request',
          'outcome': 'verified',
          'summary': 'late result must be discarded',
        });
        await tester.pump();
        final late = await pending;
        expect(late['ok'], false);
        expect(late['error']['code'], 'CLOSED');
        final invocation =
            nativeCalls.singleWhere((call) => call.method == 'invoke').arguments
                as Map;
        final cancellations = nativeCalls.where(
          (call) => call.method == 'cancelRequest',
        );
        expect(cancellations, isNotEmpty);
        for (final cancellation in cancellations) {
          expect((cancellation.arguments as Map)['owner'], invocation['owner']);
          expect(
            (cancellation.arguments as Map)['requestId'],
            invocation['requestId'],
          );
        }
        expect(
          runtimeCalls.where((call) => call.method == 'stop'),
          hasLength(1),
        );
        expect(
          find.textContaining(uncertain ? '未能确认全部退出' : '模型配置已变化'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      },
    );
  }
  testWidgets(
    'a delayed disposal cannot remove the next DSH route transport handler',
    (tester) async {
      final registry = OpenPluginRegistry();
      final package = fixtures.package(
        permissions: ['runtime.local', 'ai.generate'],
      );
      final record = OpenPluginRecord(
        package,
        enabled: true,
        grantedDigest: package.digest,
      );
      registry.records[record.manifest.id] = record;
      final starts = <int>[];
      final firstStart = Completer<void>(), secondStart = Completer<void>();
      final firstStop = Completer<void>();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(runtimeChannel, (call) async {
        final session = (call.arguments as Map)['sessionId'] as int;
        if (call.method == 'start') {
          starts.add(session);
          await (starts.length == 1 ? firstStart.future : secondStart.future);
        } else if (call.method == 'stop' && session == starts.first) {
          await firstStop.future;
        }
        return null;
      });
      addTearDown(() {
        if (!firstStart.isCompleted) firstStart.complete();
        if (!secondStart.isCompleted) secondStart.complete();
        if (!firstStop.isCompleted) firstStop.complete();
        messenger.setMockMethodCallHandler(runtimeChannel, null);
        registry.dispose();
      });
      Widget view(int id) => MaterialApp(
        home: LocalRuntimePage(
          key: ValueKey(id),
          record: record,
          registry: registry,
          component: 'org.example.runtime/org.example.runtime.Service',
          signer: 'a' * 64,
        ),
      );
      Future<void> consent() async {
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(find.text('允许本次'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
      }

      await tester.pumpWidget(view(1));
      await consent();
      expect(starts, hasLength(1));
      await tester.pumpWidget(view(2));
      await consent();
      expect(starts, hasLength(2));
      Future<void> progress(int count) => runtimeMessage('status', {
        'sessionId': starts.last,
        'phase': 'unpacking',
        'files': count,
      });
      await progress(101);
      await tester.pump();
      expect(find.textContaining('101 个文件'), findsOneWidget);
      firstStop.complete();
      firstStart.complete();
      await tester.pump();
      await progress(202);
      await tester.pump();
      expect(find.textContaining('202 个文件'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      secondStart.complete();
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );
}

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ski/assistant_plugin_tools.dart';
import 'package:ski/device_engine_plugin.dart';
import 'package:ski/open_plugin.dart';
import 'package:ski/open_plugin_network.dart';

import 'assistant_plugin_tools_test.dart' show toolPackage;
import 'open_plugin_runtime_test.dart' show fromNative;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'revoking an active assistant plugin disposes its runtime and cancels only its native request',
    () async {
      SharedPreferences.setMockInitialValues({});
      final registry = OpenPluginRegistry();
      final package = toolPackage();
      final record = OpenPluginRecord(
        package,
        enabled: true,
        grantedDigest: package.digest,
      );
      registry.records[record.manifest.id] = record;
      final tools = AssistantPluginTools(registry);
      const platform = MethodChannel('skivu/open_plugin_runtime');
      const engine = MethodChannel('skivu/device_engine');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final started = Completer<void>();
      final nativeResult = Completer<Map<String, dynamic>>();
      final pluginReply = Completer<Object?>();
      Map? invocation;
      final cancellations = <Map>[];
      String? runtimeChannel;
      var disposed = 0;
      messenger.setMockMethodCallHandler(engine, (call) async {
        if (call.method == 'invoke') {
          invocation = call.arguments as Map;
          started.complete();
          return nativeResult.future;
        }
        expect(call.method, 'cancelRequest');
        cancellations.add(call.arguments as Map);
        return {'outcome': 'cancelled'};
      });
      messenger.setMockMethodCallHandler(platform, (call) async {
        if (call.method == 'dispose') {
          disposed++;
          return null;
        }
        runtimeChannel = 'skivu/open_plugin/${(call.arguments as Map)['id']}';
        messenger.setMockMethodCallHandler(MethodChannel(runtimeChannel!), (
          event,
        ) async {
          unawaited(
            fromNative(runtimeChannel!, 'device.engine.invoke', {
              'tool': 'settings.brightness.read',
              'arguments': {},
              'requestId': 'active_assistant_plugin',
            }).then(pluginReply.complete, onError: pluginReply.completeError),
          );
          return null;
        });
        await fromNative(runtimeChannel!, 'runtime.ready', {});
        return null;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(platform, null);
        messenger.setMockMethodCallHandler(engine, null);
        if (runtimeChannel != null)
          messenger.setMockMethodCallHandler(
            MethodChannel(runtimeChannel!),
            null,
          );
        tools.dispose();
        registry.dispose();
      });

      final run = tools.invoke(
        'plugin:${record.manifest.id}/brightness',
        {},
        'assistant_call',
        () {},
      );
      final rejected = expectLater(run, throwsA(isA<PluginApiError>()));
      await started.future;
      await registry.setEnabled(record.manifest.id, false);
      await rejected;
      expect(disposed, 1);
      expect(cancellations, isNotEmpty);
      for (final cancellation in cancellations) {
        expect(cancellation['owner'], devicePluginOwner(record));
        expect(cancellation['owner'], invocation!['owner']);
        expect(cancellation['requestId'], invocation!['requestId']);
      }
      nativeResult.complete({
        'requestId': 'active_assistant_plugin',
        'outcome': 'verified',
        'value': {'mustNotReturn': true},
      });
      final late = await pluginReply.future as Map;
      expect(late['ok'], false);
      expect(late.containsKey('result'), false);
      expect(await tools.catalog(), isEmpty);
      expect(tools.active, isEmpty);
      expect(tools.activeScopes, isEmpty);
    },
  );
}

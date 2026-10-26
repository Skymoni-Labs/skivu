import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ski/open_plugin.dart';
import 'package:ski/open_plugin_companion.dart';
import 'package:ski/open_plugin_network.dart';
import 'package:ski/open_plugin_runtime.dart';
import 'open_plugin_test.dart' show TestPaths;
import 'open_plugin_companion_test.dart' show fixture;

Future<Object?> fromNative(String channel, String method, Map params) async {
  const codec = StandardMethodCodec();
  final done = Completer<Object?>();
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        channel,
        codec.encodeMethodCall(
          MethodCall(
            'request',
            jsonEncode({'id': '1', 'method': method, 'params': params}),
          ),
        ),
        (reply) {
          try {
            done.complete(codec.decodeEnvelope(reply!));
          } catch (e) {
            done.completeError(e);
          }
        },
      );
  return done.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late OpenPluginRegistry registry;
  late OpenPluginRecord record;
  const platform = MethodChannel('skivu/open_plugin_runtime');
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    temp = await Directory.systemTemp.createTemp('skivu-runtime-test-');
    PathProviderPlatform.instance = TestPaths(temp.path);
    registry = OpenPluginRegistry();
    await registry.install(fixture());
    await registry.setEnabled('test.free-plugin', true);
    await registry.bindRole(
      'test.free-plugin',
      'role',
      enabled: true,
      chat: true,
    );
    record = registry.records.values.single;
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(platform, null);
    final target = temp.resolveSymbolicLinksSync();
    expect(
      target,
      startsWith(
        Directory.systemTemp.resolveSymbolicLinksSync() +
            Platform.pathSeparator,
      ),
    );
    await temp.delete(recursive: true);
  });
  test(
    'short runtime rejects undeclared effects and always disposes the native instance',
    () async {
      final responses = <String, Map>{};
      int disposed = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(platform, (call) async {
            final id = (call.arguments as Map)['id'];
            if (call.method == 'dispose') {
              disposed++;
              return null;
            }
            final name = 'skivu/open_plugin/$id';
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                .setMockMethodCallHandler(MethodChannel(name), (event) async {
                  for (final method in [
                    'storage.compareAndSet',
                    'storage.set',
                    'storage.remove',
                    'ai.generate',
                    'chat.append',
                    'ui.openExternal',
                    'device.connect',
                    'device.apps',
                    'agent.tasks.start',
                    'agent.tasks.cancel',
                  ]) {
                    responses[method] = Map.from(
                      await fromNative(name, method, {
                            'key': 'note',
                            'value': 'forbidden',
                            'expected': null,
                          })
                          as Map,
                    );
                  }
                  await fromNative(name, 'runtime.complete', {
                    'result': {'success': true},
                  });
                  return null;
                });
            await fromNative(name, 'runtime.ready', {});
            return null;
          });
      final result = await OpenPluginRuntime(
        registry: registry,
        record: record,
        context: {'roleId': 'role'},
        effect: 'read',
        checkContext: () {},
        host: (m, p) async => throw StateError('must never reach UI'),
      ).run('read', {});
      expect((result as Map)['success'], true);
      expect(disposed, 1);
      expect(
        responses.values.every(
          (v) => v['ok'] == false && v['error']['code'] == 'PERMISSION_DENIED',
        ),
        true,
      );
      expect(await readPluginData(record.manifest.id, 'storage'), isNull);
    },
  );
  test(
    'cancellation releases runtime and late requests cannot write',
    () async {
      final invoked = Completer<String>();
      int disposed = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(platform, (call) async {
            final name = 'skivu/open_plugin/${(call.arguments as Map)['id']}';
            if (call.method == 'dispose') {
              disposed++;
              return null;
            }
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                .setMockMethodCallHandler(MethodChannel(name), (event) async {
                  if (!invoked.isCompleted) invoked.complete(name);
                  return null;
                });
            await fromNative(name, 'runtime.ready', {});
            return null;
          });
      final runtime = OpenPluginRuntime(
        registry: registry,
        record: record,
        context: {'roleId': 'role'},
        effect: 'write',
        checkContext: () {},
        host: (m, p) async => null,
      );
      final future = runtime.run('save', {});
      final expectation = expectLater(
        future,
        throwsA(
          isA<PluginApiError>().having((e) => e.code, 'code', 'CANCELLED'),
        ),
      );
      await invoked.future;
      runtime.cancel();
      await expectation;
      expect(disposed, 1);
      expect(await readPluginData(record.manifest.id, 'storage'), isNull);
    },
  );
  test(
    'a malformed later call prevents the whole proposed batch before any write',
    () async {
      int writes = 0;
      final turn = CompanionTurn(
        registry: registry,
        roleId: 'role',
        roleName: 'Role',
        chatId: 'chat',
        turnId: 'turn',
        check: () {},
        runner: (r, t, a, c, check) async {
          writes++;
          return {'success': true};
        },
      );
      await expectLater(
        turn.run(
          [],
          '',
          (h, p) async => jsonEncode({
            'reply': '',
            'calls': [
              {
                'name': 'test.free-plugin/save',
                'arguments': {'title': 'valid'},
              },
              {
                'name': 'test.free-plugin/save',
                'arguments': {'unknown': 'invalid'},
              },
            ],
            'done': false,
          }),
        ),
        throwsA(
          isA<PluginApiError>().having((e) => e.code, 'code', 'INVALID_PLAN'),
        ),
      );
      expect(writes, 0);
    },
  );
  test(
    'revoking a role binding during model generation prevents subsequent tool execution',
    () async {
      int writes = 0;
      final turn = CompanionTurn(
        registry: registry,
        roleId: 'role',
        roleName: 'Role',
        chatId: 'chat',
        turnId: 'turn',
        check: () {},
        runner: (r, t, a, c, check) async {
          writes++;
          return {'success': true};
        },
      );
      await expectLater(
        turn.run([], '', (h, p) async {
          await registry.bindRole(record.manifest.id, 'role', enabled: false);
          return jsonEncode({
            'reply': '',
            'calls': [
              {
                'name': 'test.free-plugin/save',
                'arguments': {'title': 'never'},
              },
            ],
            'done': false,
          });
        }),
        throwsA(
          isA<PluginApiError>().having((e) => e.code, 'code', 'CANCELLED'),
        ),
      );
      expect(writes, 0);
    },
  );
  test(
    'uncertain writes keep a durable intent and cannot be replayed on regeneration',
    () async {
      int writes = 0;
      CompanionTurn make() => CompanionTurn(
        registry: registry,
        roleId: 'role',
        roleName: 'Role',
        chatId: 'chat',
        turnId: 'same-user-turn',
        check: () {},
        runner: (r, t, a, c, check) async {
          writes++;
          return {'success': false};
        },
      );
      Future<String> plan(List<Map<String, String>> h, String p) async =>
          jsonEncode({
            'reply': '',
            'calls': [
              {
                'name': 'test.free-plugin/save',
                'arguments': {'title': 'maybe saved'},
              },
            ],
            'done': false,
          });
      final uncertain = throwsA(
        isA<PluginApiError>().having((e) => e.code, 'code', 'UNCERTAIN'),
      );
      await expectLater(make().run([], '', plan), uncertain);
      await expectLater(make().run([], '', plan), uncertain);
      expect(writes, 1);
      expect(
        await readPluginData(record.manifest.id, 'companion-receipts'),
        contains('pending'),
      );
    },
  );
  test(
    'revocation during a read result prevents any extra model round',
    () async {
      await registry.install(fixture(effect: 'read'));
      await registry.setEnabled('test.free-plugin', true);
      record = registry.records.values.single;
      await registry.bindRole(
        record.manifest.id,
        'role',
        enabled: true,
        chat: true,
      );
      int models = 0;
      final turn = CompanionTurn(
        registry: registry,
        roleId: 'role',
        roleName: 'Role',
        chatId: 'chat',
        turnId: 'read-turn',
        check: () {},
        runner: (r, t, a, c, check) async {
          await registry.bindRole(r.manifest.id, 'role', enabled: false);
          return {'success': true};
        },
      );
      await expectLater(
        turn.run([], '', (h, p) async {
          models++;
          return jsonEncode(
            models == 1
                ? {
                    'reply': '',
                    'calls': [
                      {
                        'name': 'test.free-plugin/save',
                        'arguments': {'title': 'read only'},
                      },
                    ],
                    'done': false,
                  }
                : {
                    'reply': 'must not request again',
                    'calls': [],
                    'done': true,
                  },
          );
        }),
        throwsA(
          isA<PluginApiError>().having((e) => e.code, 'code', 'CANCELLED'),
        ),
      );
      expect(models, 1);
    },
  );
}

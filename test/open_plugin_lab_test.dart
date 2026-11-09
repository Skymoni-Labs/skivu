import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/open_plugin.dart';
import 'package:ski/open_plugin_lab.dart';
import 'package:ski/open_plugin_network.dart';
import 'package:ski/assistant_plugin_tools.dart';
import 'open_plugin_runtime_test.dart' show fromNative;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('skivu/cloud_execution');
  late OpenPluginRecord record;
  final calls = <Map>[];
  setUp(() {
    calls.clear();
    final p = OpenPluginPackage.parse(
      File('assets/plugins/skivu-purge.skivu.json').readAsStringSync(),
    );
    record = OpenPluginRecord(p)
      ..enabled = true
      ..grantedDigest = p.digest;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(Map.from(call.arguments));
          return {
            'outcome': 'verified',
            'value': {'ok': true, 'items': []},
          };
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );
  test('current package declares only library, prompt, files and 小云 tools', () {
    expect(record.manifest.compatible, true);
    expect(record.manifest.permissions.toSet(), {
      'cloud.lab',
      'prompt',
      'files',
      'assistant.tools',
    });
    expect(record.manifest.assistantTools!['tools'], hasLength(2));
    expect(record.manifest.independentRuntime, false);
  });
  test(
    'host supplies plugin owner, read policy and stable original-call receipt',
    () async {
      for (var i = 0; i < 2; i++) {
        await invokePluginLab(
          record,
          {
            'request': {'op': 'bootstrap'},
          },
          assistant: true,
          readOnly: true,
          callId: 'same-original-call',
        );
      }
      expect(calls[0]['owner'], 'plugin:org.skivu.purge');
      expect(calls[0]['arguments'], {
        'request': {'op': 'bootstrap'},
        'assistant': true,
        'readOnly': true,
      });
      expect(calls[0]['requestId'], calls[1]['requestId']);
      expect(jsonEncode(calls), isNot(contains('command')));
    },
  );
  test('disabled plugin cannot dispatch to embedded environment', () async {
    record.enabled = false;
    await expectLater(
      invokePluginLab(record, {
        'request': {'op': 'bootstrap'},
      }),
      throwsA(isA<PluginApiError>()),
    );
    expect(calls, isEmpty);
  });
  test('unknown receipt stays unknown and is not replayed', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(Map.from(call.arguments));
          return {'outcome': 'unknown', 'message': '原回执中断，请查询原状态'};
        });
    await expectLater(
      invokePluginLab(record, {
        'request': {'op': 'import', 'engagement': 'fixture'},
      }),
      throwsA(isA<PluginApiError>().having((e) => e.code, 'code', 'UNKNOWN')),
    );
    expect(calls, hasLength(1));
  });
  test('小云 retains a plugin unknown result as unknown', () async {
    final registry = OpenPluginRegistry()..records[record.manifest.id] = record;
    final tools = AssistantPluginTools(registry);
    const platform = MethodChannel('skivu/open_plugin_runtime');
    String? activeChannel;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(platform, (call) async {
          if (call.method == 'create') {
            activeChannel =
                'skivu/open_plugin/${(call.arguments as Map)['id']}';
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                .setMockMethodCallHandler(MethodChannel(activeChannel!), (
                  event,
                ) async {
                  if (event.method == 'event')
                    await fromNative(activeChannel!, 'runtime.complete', {
                      'result': {
                        'ok': false,
                        'outcome': 'unknown',
                        'code': 'UNKNOWN',
                      },
                    });
                  return null;
                });
            await fromNative(activeChannel!, 'runtime.ready', {});
          }
          return null;
        });
    try {
      final result = await tools.invoke(
        'plugin:org.skivu.purge/record',
        {'request': '{"op":"import","engagement":"fixture"}'},
        'unknown_outer_receipt',
        () {},
      );
      expect(result.outcome, 'unknown');
      expect(result.data['value']['businessVerified'], false);
    } finally {
      tools.dispose();
      registry.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(platform, null);
      if (activeChannel != null)
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(MethodChannel(activeChannel!), null);
    }
  });
}

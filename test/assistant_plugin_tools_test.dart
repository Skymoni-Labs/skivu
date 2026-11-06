import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/assistant_plugin_tools.dart';
import 'package:ski/device_engine.dart';
import 'package:ski/device_engine_plugin.dart';
import 'package:ski/open_plugin.dart';
import 'package:ski/open_plugin_network.dart';
import 'open_plugin_test.dart' as fixture;

OpenPluginPackage toolPackage({bool permission = true}) {
  final manifest = fixture.manifest(
    permissions: [if (permission) 'assistant.tools', 'device.observe'],
  );
  manifest['minHostVersion'] = '0.2.81';
  manifest['contributes'] = {
    'launcher': true,
    'chatActions': [],
    'assistantTools': {
      'title': 'Independent tools',
      'entry': 'index.html',
      'tools': [
        {
          'id': 'brightness',
          'description': 'Read brightness',
          'effect': 'read',
          'parameters': {
            'type': 'object',
            'properties': {},
            'required': [],
            'additionalProperties': false,
          },
        },
      ],
    },
  };
  final raw = jsonDecode(fixture.package().raw) as Map;
  raw['manifest'] = manifest;
  return OpenPluginPackage.parse(jsonEncode(raw));
}

void main() {
  test(
    'only explicitly authorized assistant contributions appear, without role binding',
    () async {
      final registry = OpenPluginRegistry();
      final package = toolPackage();
      final record = OpenPluginRecord(
        package,
        enabled: true,
        grantedDigest: package.digest,
      );
      registry.records[package.manifest.id] = record;
      final tools = AssistantPluginTools(registry);
      addTearDown(() {
        tools.dispose();
        registry.dispose();
      });
      final catalog = await tools.catalog();
      expect(catalog.single['id'], 'plugin:test.free-plugin/brightness');
      expect(record.manifest.companion, isNull);
      record.enabled = false;
      expect(await tools.catalog(), isEmpty);
      record.enabled = true;
      record.grantedDigest = 'changed';
      expect(await tools.catalog(), isEmpty);
      expect(() => toolPackage(permission: false), throwsFormatException);
    },
  );
  test(
    'closing a runtime cancels its exact native request and discards late results',
    () async {
      final registry = OpenPluginRegistry();
      final package = toolPackage();
      final record = OpenPluginRecord(
        package,
        enabled: true,
        grantedDigest: package.digest,
      );
      registry.records[package.manifest.id] = record;
      addTearDown(registry.dispose);
      final pending = Completer<Map<String, dynamic>>();
      final started = Completer<void>();
      Map<String, dynamic>? invocation, cancellation;
      final scope = DeviceEngineScope(
        engine: DeviceEngine(
          transport: (method, args) async {
            if (method == 'cancelRequest') {
              cancellation = args;
              return {};
            }
            invocation = args;
            started.complete();
            return pending.future;
          },
        ),
      );
      final request = scope.call(registry, record, 'device.engine.invoke', {
        'tool': 'settings.brightness.read',
        'arguments': {},
        'requestId': 'scope_read_1',
      });
      final rejected = expectLater(request, throwsA(isA<PluginApiError>()));
      await started.future;
      scope.close();
      pending.complete({
        'requestId': 'scope_read_1',
        'outcome': 'verified',
        'summary': 'read',
      });
      await rejected;
      expect(cancellation?['requestId'], invocation?['requestId']);
      expect(cancellation?['owner'], devicePluginOwner(record));
    },
  );
}

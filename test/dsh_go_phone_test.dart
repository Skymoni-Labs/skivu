import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/assistant_engine.dart';
import 'package:ski/device_engine.dart';
import 'package:ski/device_tool_catalog.dart';
import 'package:ski/phone_task_adapters.dart';

void main() {
  setUp(dshGoDeviceTools.clear);
  tearDown(dshGoDeviceTools.clear);
  Map<String, dynamic> schema(String name) => {
    'name': name,
    'description': 'Original native $name',
    'inputSchema': {
      'type': 'object',
      'properties': <String, dynamic>{},
      'additionalProperties': false,
    },
  };
  test(
    'catalog uses native schemas and removes the parallel screen executor',
    () async {
      final calls = <String>[];
      final engine = DeviceEngine(
        transport: (method, args) async {
          calls.add(method);
          if (method == 'status')
            return {'backend': 'dsh-go', 'enabled': false};
          return {
            'tools': [schema('screen'), schema('apps'), schema('intent')],
          };
        },
      );
      final catalog = await engine.catalog();
      expect(
        catalog.map((e) => e['id']),
        containsAll([
          'phone.screen',
          'phone.apps',
          'phone.intent',
          'device.receipt',
        ]),
      );
      expect(
        catalog.any((e) => (e['id'] as String).startsWith('ui.')),
        isFalse,
      );
      expect(catalog.every((e) => e['available'] == true), isTrue);
      expect(
        deviceTool('phone.screen').parameters,
        schema('screen')['inputSchema'],
      );
      expect(await PhoneTaskAdapters(() => null).catalog(), isEmpty);
      expect(await engine.previousEffect('phone.intent', {}), {'found': false});
      expect(calls, ['status', 'catalog']);
    },
  );
  test(
    'a scoped catalog never grants an omitted native or status tool',
    () async {
      var dispatches = 0;
      final engine = DeviceEngine(
        allowedTools: {'phone.screen'},
        transport: (method, args) async {
          if (method == 'status') return {'backend': 'dsh-go'};
          if (method == 'catalog')
            return {
              'tools': [schema('screen'), schema('tap')],
            };
          dispatches++;
          return {
            'requestId': args['requestId'],
            'outcome': 'verified',
            'summary': 'native',
          };
        },
      );
      expect((await engine.catalog()).map((e) => e['id']), ['phone.screen']);
      await expectLater(
        engine.invoke('phone.tap', {}, owner: 'assistant:scope'),
        throwsFormatException,
      );
      await expectLater(
        engine.invoke('device.status', {}, owner: 'assistant:scope'),
        throwsFormatException,
      );
      expect(dispatches, 0);
    },
  );
  test(
    'phone invoke discovers the original schema and keeps host request identity',
    () async {
      final engine = DeviceEngine(
        transport: (method, args) async {
          if (method == 'status') return {'backend': 'dsh-go'};
          if (method == 'catalog')
            return {
              'tools': [schema('screen')],
            };
          expect(args['owner'], 'assistant:task');
          expect(args['requestId'], 'original');
          expect(args['tool'], 'phone.screen');
          return {
            'requestId': args['requestId'],
            'outcome': 'verified',
            'summary': 'native',
          };
        },
      );
      expect(
        (await engine.invoke(
          'phone.screen',
          {},
          owner: 'assistant:task',
          requestId: 'original',
        )).verified,
        isTrue,
      );
      await expectLater(
        engine.invoke('phone.screen', {
          'invented': true,
        }, owner: 'assistant:task'),
        throwsFormatException,
      );
    },
  );
  test(
    'original MCP image reaches the next model request as an image, once',
    () async {
      const pixels = 'aGVsbG8=';
      var requests = 0;
      final engine = DeviceEngine(
        transport: (method, args) async {
          if (method == 'status') return {'backend': 'dsh-go'};
          if (method == 'catalog')
            return {
              'tools': [schema('screen')],
            };
          return {
            'requestId': args['requestId'],
            'outcome': 'verified',
            'summary': 'native',
            'value': {
              'content': [
                {'type': 'text', 'text': 's1 native screen'},
                {'type': 'image', 'mimeType': 'image/png', 'data': pixels},
              ],
              'isError': false,
            },
          };
        },
      );
      final assistant = AssistantEngine(
        engine: engine,
        identity: () => 'test-model',
        read: () async => null,
        write: (_) async {},
        model: (system, history) async {
          requests++;
          expect(system, contains('dsh-go 的 phone.*'));
          expect(system, contains('screen 和 id'));
          if (requests == 1)
            return jsonEncode({
              'type': 'call',
              'tool': 'phone.screen',
              'arguments': {},
              'message': '读取屏幕',
            });
          final receipt = history.lastWhere((e) => e['image'] != null);
          expect(receipt['image'], 'data:image/png;base64,$pixels');
          expect(receipt['content'], contains('s1 native screen'));
          expect(receipt['content'], isNot(contains(pixels)));
          return jsonEncode({'type': 'final', 'message': '屏幕读取完成'});
        },
      );
      await assistant.send('读取当前屏幕');
      expect(assistant.phase, 'done');
      expect(requests, 2);
      assistant.dispose();
    },
  );
}

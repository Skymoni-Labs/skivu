import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ski/assistant_stream_preview.dart';
import 'package:ski/chat_api.dart';
import 'package:ski/cloud_conversations.dart';
import 'package:ski/device_engine.dart';
import 'package:ski/state.dart';
import 'real_chat_store_test.dart' show MemoryChats, TestModels;

Future<void> until(bool Function() check) async {
  for (var i = 0; i < 400 && !check(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(check(), true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(DeviceEngine.channel, (call) async {
          if (call.method == 'status') return {'enabled': true};
          if (call.method == 'session.start' || call.method == 'session.end')
            return {};
          if (call.method == 'cancelRequest') return {'outcome': 'cancelled'};
          throw StateError('Unexpected device effect: ${call.method}');
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(DeviceEngine.channel, null),
  );

  test(
    'only top-level final text is revealed, including split Unicode escapes',
    () {
      expect(
        assistantFinalPrefix(r'{"type":"final","message":"你好\n世界\uD83D'),
        '你好\n世界',
      );
      expect(
        assistantFinalPrefix(
          r'{"type":"final","message":"你好\n世界\uD83D\uDE00"}',
        ),
        '你好\n世界😀',
      );
      expect(
        assistantFinalPrefix(
          r'{"type":"call","arguments":{"type":"final","message":"secret"}}',
        ),
        isNull,
      );
      expect(
        assistantFinalPrefix(r'{"message":"hello","type":"final"}'),
        'hello',
      );
      expect(
        assistantFinalPrefix(
          r'{"type":"final","type":"call","message":"secret"}',
        ),
        isNull,
      );
      expect(
        assistantFinalPrefix(r'{"type":"final","message":"split\'),
        'split',
      );
    },
  );

  test(
    'Cloud honors streaming and shows reasoning and final text before EOF without duplicate replies',
    () async {
      final packets = StreamController<List<int>>();
      Map? wire;
      final store = DemoStore(
        settings: TestModels(),
        storage: MemoryChats(),
        api: ChatApi(
          clientFactory: () => MockClient.streaming((request, body) async {
            wire = jsonDecode(await body.bytesToString()) as Map;
            return http.StreamedResponse(
              packets.stream,
              200,
              headers: {'content-type': 'text/event-stream'},
            );
          }),
        ),
      );
      await store.restore();
      CloudChatCoordinator(store).attach();
      store.newChat(personaId: cloudPersonaId);
      expect(store.send('测试流式'), true);
      await until(() => wire != null);
      expect(wire!['stream'], true);
      void chunk(Map<String, String> delta) => packets.add(
        utf8.encode(
          'data: ${jsonEncode({
            'choices': [
              {'delta': delta},
            ],
          })}\n\n',
        ),
      );
      chunk({'reasoning_content': '先想一想'});
      await until(() => store.messages.last.thinking == '先想一想');
      chunk({'content': '{"type":"final","message":"第一段'});
      await until(() => store.messages.last.text == '第一段');
      expect(store.streaming, true);
      expect(store.messages.last.status, 'pending');
      expect(store.messages.last.text, isNot(contains('"type"')));
      chunk({'content': '，第二段。"}'});
      packets.add(utf8.encode('data: [DONE]\n\n'));
      await packets.close();
      await until(() => !store.streaming);
      expect(store.messages.where((m) => !m.user), hasLength(1));
      expect(store.messages.last.text, '第一段，第二段。');
      expect(store.messages.last.thinking, '先想一想');
      expect(store.messages.last.status, 'complete');
      store.dispose();
    },
  );

  for (final override in [false, true]) {
    test(
      'disabled streaming stays off on the wire and reasoning is kept (override: $override)',
      () async {
        final models = TestModels();
        if (!override)
          models.connections[0] = models.connections.first.withStreaming(false);
        Map? wire;
        final store = DemoStore(
          settings: models,
          storage: MemoryChats(),
          api: ChatApi(
            clientFactory: () => MockClient((request) async {
              wire = jsonDecode(request.body) as Map;
              return http.Response(
                jsonEncode({
                  'choices': [
                    {
                      'message': {
                        'content': '{"type":"final","message":"完整回复"}',
                        'reasoning_content': '非流式思考',
                      },
                    },
                  ],
                }),
                200,
                headers: {'content-type': 'application/json'},
              );
            }),
          ),
        );
        await store.restore();
        CloudChatCoordinator(store).attach();
        store.newChat(personaId: cloudPersonaId);
        store.send('关闭流式', streamingOverride: override ? false : null);
        await until(() => !store.streaming);
        expect(wire!['stream'], false);
        expect(store.messages.last.text, '完整回复');
        expect(store.messages.last.thinking, '非流式思考');
        store.dispose();
      },
    );
  }

  test(
    'stopping a streamed reply preserves its prefix and ignores later packets',
    () async {
      final packets = StreamController<List<int>>();
      final store = DemoStore(
        settings: TestModels(),
        storage: MemoryChats(),
        api: ChatApi(
          clientFactory: () => MockClient.streaming((_, body) async {
            await body.drain<void>();
            return http.StreamedResponse(
              packets.stream,
              200,
              headers: {'content-type': 'text/event-stream'},
            );
          }),
        ),
      );
      await store.restore();
      CloudChatCoordinator(store).attach();
      store.newChat(personaId: cloudPersonaId);
      store.send('停止测试');
      packets.add(
        utf8.encode(
          'data: ${jsonEncode({
            'choices': [
              {
                'delta': {'content': '{"type":"final","message":"已收到前缀'},
              },
            ],
          })}\n\n',
        ),
      );
      await until(() => store.messages.last.text == '已收到前缀');
      store.stop();
      packets.add(
        utf8.encode(
          'data: ${jsonEncode({
            'choices': [
              {
                'delta': {'content': '迟到内容"}'},
              },
            ],
          })}\n\n',
        ),
      );
      packets.add(utf8.encode('data: [DONE]\n\n'));
      await packets.close();
      await until(
        () => !store.streaming && store.messages.last.status == 'cancelled',
      );
      expect(
        store.messages.where((m) => !m.user).map((m) => m.text).join(),
        contains('已收到前缀'),
      );
      expect(
        store.messages.where((m) => !m.user).map((m) => m.text).join(),
        isNot(contains('迟到内容')),
      );
      expect(store.messages.last.status, 'cancelled');
      store.dispose();
    },
  );
}

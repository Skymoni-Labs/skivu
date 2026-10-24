import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ski/chat_api.dart';
import 'package:ski/state.dart';
import 'package:ski/ui_host_binding.dart';
import 'package:ski/voice_call_session.dart';
import 'real_chat_store_test.dart' show MemoryChats, TestModels;

DemoStore groupStore({
  String rule = 'roundRobin',
  Future<http.Response> Function(http.Request)? response,
}) {
  var calls = 0;
  final store = DemoStore(
    storage: MemoryChats(),
    settings: TestModels(),
    api: ChatApi(
      clientFactory: () => MockClient(
        response ??
            (r) async => http.Response(
              jsonEncode({
                'choices': [
                  {
                    'message': {'content': '角色回复${++calls}'},
                  },
                ],
              }),
              200,
              headers: {'content-type': 'application/json'},
            ),
      ),
    ),
  );
  UiHostBinding(store).mutate({
    'protocol': 1,
    'command': 'createGroup',
    'members': store.personas.take(2).map((p) => p.id).toList(),
    'title': '语音群聊',
    'rule': rule,
    'maxReplies': 2,
  });
  return store;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'voice returns all assistants from its own group turn with authors',
    () async {
      final store = groupStore();
      await store.restore();
      store.messages.add(Message(false, '旧回复，不朗读'));
      final backend = CurrentChatVoiceBackend(store: store);
      final partials = <String>[];
      final result = await backend.reply('开始这一轮', partials.add);
      expect(result, '角色回复1\n\n角色回复2');
      expect(
        backend.replyParts.map((p) => p.speaker),
        store.personas.take(2).map((p) => p.name),
      );
      expect(partials.join(), isNot(contains('旧回复，不朗读')));
      expect(result, isNot(contains('开始这一轮')));
      backend.dispose();
      store.dispose();
    },
  );

  test('mention-only silence produces no assistant or user echo', () async {
    var requests = 0;
    final store = groupStore(
      rule: 'mentions',
      response: (r) async {
        requests++;
        return http.Response('{}', 200);
      },
    );
    await store.restore();
    final backend = CurrentChatVoiceBackend(store: store);
    final result = await backend.reply('没有点名的用户输入', (_) {});
    expect(requests, 0);
    expect(result, isEmpty);
    expect(backend.replyParts, isEmpty);
    expect(store.messages.last.user, isTrue);
    backend.dispose();
    store.dispose();
  });

  test(
    'cancelled group never returns late content or starts another member',
    () async {
      final pending = Completer<http.Response>(), started = Completer<void>();
      var requests = 0;
      final store = groupStore(
        response: (r) {
          requests++;
          started.complete();
          return pending.future;
        },
      );
      await store.restore();
      final backend = CurrentChatVoiceBackend(store: store);
      final reply = backend.reply('待取消的轮次', (_) {});
      await started.future;
      await backend.cancelReply();
      expect(await reply, isEmpty);
      pending.complete(
        http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': '迟到内容'},
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(requests, 1);
      expect(backend.replyParts, isEmpty);
      backend.dispose();
      store.dispose();
    },
  );

  test('session captions and speech retain separate group authors', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final store = groupStore();
    await store.restore();
    final backend = CurrentChatVoiceBackend(store: store);
    const channel = MethodChannel('skivu/voice_call');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final spoken = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'speak') {
        spoken.add((call.arguments as Map)['text'] as String);
        scheduleMicrotask(() {
          messenger.handlePlatformMessage(
            'skivu/voice_call',
            const StandardMethodCodec().encodeMethodCall(
              const MethodCall('ttsDone', {}),
            ),
            (_) {},
          );
        });
      }
      return call.method == 'listen' ? 'listening' : null;
    });
    final session = VoiceCallSession(backend: backend);
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      debugDefaultTargetPlatformOverride = null;
    });
    await session.start();
    await session.sendText('开始');
    expect(spoken, ['角色回复1', '角色回复2']);
    expect(
      session.transcript.skip(1).map((p) => p.speaker),
      store.personas.take(2).map((p) => p.name),
    );
    expect(session.transcript.skip(1).map((p) => p.text), spoken);
    await session.end();
    session.dispose();
    store.dispose();
  });
}

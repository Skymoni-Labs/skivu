import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ski/assistant_engine.dart';
import 'package:ski/chat_api.dart';
import 'package:ski/cloud_conversations.dart';
import 'package:ski/device_engine.dart';
import 'package:ski/open_plugin.dart';
import 'package:ski/state.dart';
import 'open_plugin_test.dart' show package;
import 'real_chat_store_test.dart' show MemoryChats, TestModels, waitForReply;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const id = 'test.prompt-prefix';
  const prefix = 'user-configured-prefix\r\nkeep original bytes';
  late OpenPluginRecord? previous;
  late Map<String, String>? previousPrompts;

  setUp(() {
    previous = openPlugins.records[id];
    previousPrompts = openPlugins.promptContributions[id];
    final plugin = package(id: id, permissions: ['prompt']);
    openPlugins.records[id] = OpenPluginRecord(
      plugin,
      enabled: true,
      grantedDigest: plugin.digest,
    );
    openPlugins.promptContributions[id] = {cloudPersonaId: prefix};
  });

  tearDown(() {
    if (previous == null) {
      openPlugins.records.remove(id);
    } else {
      openPlugins.records[id] = previous!;
    }
    if (previousPrompts == null) {
      openPlugins.promptContributions.remove(id);
    } else {
      openPlugins.promptContributions[id] = previousPrompts!;
    }
  });

  http.Response response(String content) => http.Response(
    jsonEncode({
      'choices': [
        {
          'message': {'content': content},
          'finish_reason': 'stop',
        },
      ],
    }),
    200,
    headers: {'content-type': 'application/json'},
  );

  test(
    'each cloud tool round sends the raw prefix first and only once',
    () async {
      final bodies = <Map<String, dynamic>>[];
      final store = DemoStore(
        settings: TestModels(),
        storage: MemoryChats(),
        api: ChatApi(
          clientFactory: () => MockClient((request) async {
            bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
            return response(
              bodies.length == 1
                  ? '{"type":"call","tool":"workflow.state","arguments":{},"message":"read saved state"}'
                  : '{"type":"final","message":"complete"}',
            );
          }),
        ),
      );
      try {
        await store.restore();
        CloudChatCoordinator(
          store,
          engineFactory: (_) => AssistantEngine(
            identity: () => 'test',
            read: () async => null,
            write: (_) async {},
            engine: DeviceEngine(transport: (_, _) async => {'enabled': false}),
            model: (system, history) async {
              final session = await store.startAssistantReply(system, history);
              final text = StringBuffer();
              await for (final event in session.events) {
                text.write(event.text);
              }
              return text.toString();
            },
          ),
        ).attach();
        store.newChat(personaId: cloudPersonaId);
        expect(store.send('perform a read-only test'), true);
        await waitForReply(store);
        expect(bodies.length, 2);
        for (final body in bodies) {
          final messages = body['messages'] as List;
          expect(messages.first['role'], 'system');
          expect(
            (messages.first['content'] as String).startsWith(prefix),
            true,
          );
          final all = messages.map((m) => m['content']).join('\n');
          expect(all.split(prefix).length - 1, 1);
          expect(all.contains('用户启用的插件'), false);
          expect(all.contains('第三方指导'), false);
        }
        expect(store.messages.any((m) => m.text.contains(prefix)), false);

        openPlugins.promptContributions[id] = {cloudPersonaId: ''};
        expect(store.send('after revocation'), true);
        await waitForReply(store);
        expect(
          jsonEncode(bodies.last).contains('user-configured-prefix'),
          false,
        );
        openPlugins.promptContributions[id] = {cloudPersonaId: prefix};
        openPlugins.records[id]!.enabled = false;
        expect(store.send('after disable'), true);
        await waitForReply(store);
        expect(
          jsonEncode(bodies.last).contains('user-configured-prefix'),
          false,
        );
      } finally {
        store.dispose();
      }
    },
  );

  test(
    'assistant and device transports keep the prefix ahead of host instructions',
    () async {
      final bodies = <Map<String, dynamic>>[];
      final store = DemoStore(
        settings: TestModels(),
        storage: MemoryChats(),
        api: ChatApi(
          clientFactory: () => MockClient((request) async {
            bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
            return response('complete');
          }),
        ),
      );
      try {
        await store.restore();
        final sessions = [
          await store.startAssistantReply('host instructions', []),
          await store.startAssistantReply(
            'scheduled host instructions',
            [],
            maxOutputTokens: 512,
          ),
          await store.startAssistantReply('$prefix\n\nhost instructions', []),
          await store.startDeviceReply('inspect the screen', 512),
          await store.startPluginReply(cloudPersonaId, 'model tool', [], 512),
          await store.startSocialReply(cloudPersonaId, 'social job'),
        ];
        for (final session in sessions) {
          await session.events.toList();
          final system =
              (bodies.last['messages'] as List).first['content'] as String;
          expect(system.startsWith(prefix), true);
          expect(system.split(prefix).length - 1, 1);
        }
        final cloud = store.personas.firstWhere((p) => p.id == cloudPersonaId);
        expect(store.promptFor(cloud).startsWith(prefix), true);
        expect(
          store.promptFor(cloud, includePluginPrompt: false).contains(prefix),
          false,
        );
        final other = store.personas.firstWhere((p) => !p.isCloud);
        expect(store.promptFor(other).contains(prefix), false);
      } finally {
        store.dispose();
      }
    },
  );
}

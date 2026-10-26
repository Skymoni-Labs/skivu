import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ski/open_plugin.dart';
import 'package:ski/open_plugin_tools.dart';
import 'package:ski/chat_api.dart';
import 'package:ski/state.dart';
import 'open_plugin_test.dart' show manifest, TestPaths;
import 'real_chat_store_test.dart' show MemoryChats, TestModels;

OpenPluginPackage fixture() {
  final m = manifest(permissions: ['storage', 'chat.tools']);
  m['minHostVersion'] = '0.2.41';
  m['contributes'] = {
    'launcher': false,
    'chatActions': [
      {'id': 'open', 'title': 'Open'},
    ],
    'chatSurface': false,
    'roleCompanion': {
      'title': '角色道具',
      'entry': 'task.html',
      'tools': [
        {
          'id': 'save',
          'description': 'Save a note',
          'effect': 'write',
          'parameters': {
            'type': 'object',
            'properties': {
              'title': {'type': 'string', 'maxLength': 100},
            },
            'required': ['title'],
            'additionalProperties': false,
          },
        },
      ],
    },
  };
  return OpenPluginPackage.parse(
    jsonEncode({
      'manifest': m,
      'files': {
        for (final name in ['index.html', 'task.html'])
          name: {
            'mime': 'text/html',
            'base64': base64Encode(utf8.encode('<p>Fixture</p>')),
          },
      },
      'licenseText': 'MIT fixture',
      'notices': '',
    }),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    temp = await Directory.systemTemp.createTemp('skivu-companion-test-');
    PathProviderPlatform.instance = TestPaths(temp.path);
  });
  tearDown(() async {
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
    'role binding is explicit, persisted and does not select a chat surface',
    () async {
      final r = OpenPluginRegistry();
      await r.install(fixture());
      await r.setEnabled('test.free-plugin', true);
      expect(r.companionsFor('role').isEmpty, true);
      await r.bindRole('test.free-plugin', 'role', enabled: true);
      expect(r.companionsFor('role').length, 1);
      expect(r.companionsFor('role', tools: true).isEmpty, true);
      await r.bindRole('test.free-plugin', 'role', enabled: true, chat: true);
      // A previously selected replacement surface must not survive a manifest
      // that now declares the same plugin as an auxiliary role item.
      await (await SharedPreferences.getInstance()).setString(
        'skivu.open-plugin.chat-surface',
        'test.free-plugin',
      );
      final restored = OpenPluginRegistry();
      await restored.restore();
      expect(restored.companionsFor('role', tools: true).length, 1);
      expect(restored.companionsFor('other').isEmpty, true);
      expect(restored.chatSurface, isNull);
      final record = restored.records.values.single;
      expect(
        restored.companionContext(record, 'role', 'Name', 'a')['spaceId'],
        isNot(
          restored.companionContext(record, 'role', 'Name', 'b')['spaceId'],
        ),
      );
      await restored.setEnabled(record.manifest.id, false);
      expect(restored.companionsFor('role').isEmpty, true);
    },
  );
  test('schema rejects unknown or unbounded argument structures', () {
    expect(
      () => validatePluginSchema({
        'type': 'object',
        'properties': {},
        'required': [],
      }),
      throwsFormatException,
    );
    final schema = {
      'type': 'object',
      'properties': {
        'title': {'type': 'string', 'maxLength': 4},
      },
      'required': ['title'],
      'additionalProperties': false,
    };
    expect(
      () => validatePluginArguments({'title': '12345'}, schema),
      throwsFormatException,
    );
    expect(
      () => validatePluginArguments({'title': 'ok', 'extra': true}, schema),
      throwsFormatException,
    );
  });
  test(
    'ordinary chat executes namespaced tool once, shows final reply and persists a record card',
    () async {
      final registry = OpenPluginRegistry();
      await registry.install(fixture());
      await registry.setEnabled('test.free-plugin', true);
      final bodies = <Map>[];
      int rounds = 0, writes = 0;
      final storage = MemoryChats();
      final api = ChatApi(
        clientFactory: () => MockClient((request) async {
          bodies.add(jsonDecode(request.body));
          final plan = rounds++ == 0
              ? {
                  'reply': '',
                  'calls': [
                    {
                      'name': 'test.free-plugin/save',
                      'arguments': {'title': '明天去书店'},
                    },
                  ],
                  'done': false,
                }
              : {'reply': '我记下来了，明天一起去。', 'calls': [], 'done': true};
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': jsonEncode(plan)},
                },
              ],
              'usage': {'prompt_tokens': 10, 'completion_tokens': 5},
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      final store = DemoStore(
        api: api,
        settings: TestModels(),
        storage: storage,
        plugins: registry,
        companionRunner: (record, tool, args, context, check) async {
          check();
          writes++;
          expect(context['roleId'], storeRole);
          expect(context.keys, containsAll(['spaceId', 'chatId', 'callId']));
          expect(tool['id'], 'save');
          return {
            'success': true,
            'card': {
              'title': '日程已保存',
              'summary': args['title'],
              'action': 'open',
              'payload': {'id': 'record1'},
            },
          };
        },
      );
      await store.restore();
      storeRole = store.role.id;
      await registry.bindRole(
        'test.free-plugin',
        storeRole,
        enabled: true,
        chat: true,
      );
      expect(store.send('明天陪你去书店，记下来吧'), true);
      final finished = Completer<void>();
      void replyChanged() {
        if (!store.streaming && !finished.isCompleted) finished.complete();
      }

      store.addListener(replyChanged);
      replyChanged();
      await finished.future.timeout(const Duration(seconds: 10));
      store.removeListener(replyChanged);
      await store.saveChats();
      expect(store.streaming, false);
      expect(
        store.messages.last.status,
        'complete',
        reason: store.messages.last.error,
      );
      expect(store.messages.last.text, '我记下来了，明天一起去。');
      expect(writes, 1);
      expect(bodies.length, 2);
      expect(store.messages.length, 2);
      expect(store.messages.last.pluginCards.single['title'], '日程已保存');
      expect(store.messages.last.tokens, 10);
      expect(store.conversations[store.conversation].usage.totalTokens, 30);
      expect(store.conversations[store.conversation].usedTokens, 30);
      expect(storage.data, contains('pluginCards'));
      expect(storage.data, isNot(contains('test-key-only')));
      store.dispose();
    },
  );
  test(
    'removing the speaking group member stops its pending phone tools',
    () async {
      final registry = OpenPluginRegistry();
      await registry.install(fixture());
      await registry.setEnabled('test.free-plugin', true);
      final started = Completer<void>(), plan = Completer<String>();
      int writes = 0;
      final api = ChatApi(
        clientFactory: () => MockClient((request) async {
          if (!started.isCompleted) started.complete();
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': await plan.future},
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      final store = DemoStore(
        api: api,
        settings: TestModels(),
        storage: MemoryChats(),
        plugins: registry,
        companionRunner: (r, t, a, c, check) async {
          writes++;
          return {'success': true};
        },
      );
      await store.restore();
      final role = store.role, chat = store.conversations[store.conversation];
      chat.groupMembers = [role.id];
      chat.groupRule = 'manual';
      await registry.bindRole(
        'test.free-plugin',
        role.id,
        enabled: true,
        chat: true,
      );
      expect(store.send('记下一件事'), true);
      await started.future.timeout(const Duration(seconds: 10));
      chat.groupMembers.clear();
      final finished = Completer<void>();
      void changed() {
        if (!store.streaming && !finished.isCompleted) finished.complete();
      }

      store.addListener(changed);
      plan.complete(
        jsonEncode({
          'reply': '',
          'calls': [
            {
              'name': 'test.free-plugin/save',
              'arguments': {'title': '不得执行'},
            },
          ],
          'done': false,
        }),
      );
      await finished.future.timeout(const Duration(seconds: 10));
      store.removeListener(changed);
      expect(writes, 0);
      expect(store.messages.last.status, 'failed');
      store.dispose();
    },
  );
}

String storeRole = '';

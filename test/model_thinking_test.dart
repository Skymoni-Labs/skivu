import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:ski/chat_api.dart';
import 'package:ski/model_connection.dart';
import 'package:ski/model_settings.dart';

ModelConnection config({bool? thinking}) => ModelConnection(
  id: 'deepseek',
  name: 'DeepSeek',
  provider: '自定义兼容接口',
  protocol: ApiProtocol.chat,
  address: 'https://api.deepseek.com/v1',
  model: 'deepseek-flash',
  streaming: false,
  thinkingEnabled: thinking,
);

http.Response response() => http.Response(
  '{"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}]}',
  200,
  headers: {'content-type': 'application/json'},
);

class CountingSecureStorage extends FlutterSecureStorage {
  int reads = 0, writes = 0;

  @override
  Future<String?> read({
    required String key,
    dynamic options,
    dynamic iOptions,
    dynamic aOptions,
    dynamic lOptions,
    dynamic wOptions,
    dynamic mOptions,
    dynamic webOptions,
  }) async {
    reads++;
    return super.read(key: key);
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    dynamic options,
    dynamic iOptions,
    dynamic aOptions,
    dynamic lOptions,
    dynamic wOptions,
    dynamic mOptions,
    dynamic webOptions,
  }) async {
    writes++;
    return super.write(key: key, value: value);
  }
}

class FailingPreferences extends InMemorySharedPreferencesStore {
  FailingPreferences() : super.empty();
  bool failNext = false;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (failNext) {
      failNext = false;
      return false;
    }
    return super.setValue(valueType, key, value);
  }
}

class DelayedPreferences extends InMemorySharedPreferencesStore {
  DelayedPreferences() : super.empty();
  final gates = <Completer<void>>[];

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (gates.isNotEmpty) await gates.removeAt(0).future;
    return super.setValue(valueType, key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  test(
    'old configurations follow the provider and explicit values round trip',
    () {
      final old = config().toJson()..remove('thinkingEnabled');
      final restored = ModelConnection.fromJson(old);
      expect(restored.thinkingEnabled, isNull);
      expect(restored.supportsThinking, isTrue);
      expect(restored.effectiveThinkingEnabled, isTrue);
      for (final value in [true, false]) {
        final saved = ModelConnection.fromJson(
          config(thinking: value).toJson(),
        );
        expect(saved.thinkingEnabled, value);
        expect(saved.withStreaming(true).thinkingEnabled, value);
        expect(saved.effectiveThinkingEnabled, value);
      }
    },
  );

  test(
    'thinking capability requires documented direct models and endpoint',
    () {
      for (final override in [
        {'address': 'https://models.example/v1'},
        {'address': 'https://api.deepseek.com.attacker.example/v1'},
        {'address': 'http://api.deepseek.com/v1'},
        {'address': 'https://api.deepseek.com:8443/v1'},
        {'protocol': 'responses'},
        {'model': 'unknown-model'},
      ]) {
        final unsupported = ModelConnection.fromJson({
          ...config(thinking: false).toJson(),
          ...override,
          'provider': 'DeepSeek',
        });
        expect(unsupported.supportsThinking, isFalse);
        expect(unsupported.effectiveThinkingEnabled, isNull);
      }
      expect(
        ModelConnection.fromJson({
          ...config().toJson(),
          'model': 'deepseek-v4-pro',
        }).supportsThinking,
        isTrue,
      );
    },
  );

  test(
    'ordinary direct and agent requests send explicit thinking values',
    () async {
      for (final value in [null, true, false]) {
        final expected = value == null
            ? null
            : {'type': value ? 'enabled' : 'disabled'};
        final ordinary = ChatSession(
          MockClient((request) async {
            final body = jsonDecode(request.body) as Map;
            expect(body['thinking'], expected);
            expect(body.containsKey('thinking'), value != null);
            return response();
          }),
          config(thinking: value),
          'fixture-key',
          [],
          'test',
        );
        expect((await ordinary.events.toList()).single.text, 'ok');
        final agent = AgentChatSession.custom(
          MockClient((request) async {
            final body = jsonDecode(request.body) as Map;
            expect(body['thinking'], expected);
            expect(body.containsKey('thinking'), value != null);
            return response();
          }),
          config(thinking: value),
          'fixture-key',
        );
        await agent.send(
          messages: [
            {'role': 'user', 'content': 'test'},
          ],
          tools: [],
        );
      }
    },
  );

  test(
    'provider fields stay out of unknown endpoints and account transports',
    () async {
      final unknown = ModelConnection.fromJson({
        ...config(thinking: false).toJson(),
        'address': 'https://models.example/v1',
      });
      MockClient client() => MockClient((request) async {
        expect(
          (jsonDecode(request.body) as Map).containsKey('thinking'),
          isFalse,
        );
        return response();
      });
      await ChatSession(
        client(),
        unknown,
        'fixture-key',
        [],
        'test',
      ).events.toList();
      await AgentChatSession.custom(client(), unknown, 'fixture-key').send(
        messages: [
          {'role': 'user', 'content': 'test'},
        ],
        tools: [],
      );
      await ChatSession.account(
        client(),
        config(thinking: false),
        [],
        'test',
        'token',
      ).events.toList();
      await ChatSession.beta(
        client(),
        config(thinking: false),
        [],
        'test',
        (_) async => {},
      ).events.toList();
      await AgentChatSession.account(
        client(),
        config(thinking: true),
        'token',
      ).send(
        messages: [
          {'role': 'user', 'content': 'test'},
        ],
        tools: [],
      );
    },
  );

  test(
    'thinking updates serialize with selection and leave credentials untouched',
    () async {
      final secure = CountingSecureStorage();
      final settings = ModelSettings(secure: secure);
      addTearDown(settings.dispose);
      await settings.save(config(), 'private-fixture');
      final second = ModelConnection.fromJson({
        ...config().toJson(),
        'id': 'other',
      });
      await settings.save(second, 'other-fixture');
      final reads = secure.reads, writes = secure.writes;
      final credentials = settings.connections
          .map((c) => c.credentialId)
          .toList();
      await Future.wait([
        settings.setThinkingEnabled('deepseek', false),
        settings.select('other'),
        settings.setThinkingEnabled('deepseek', true),
        settings.setThinkingEnabled('deepseek', false),
      ]);
      expect(settings.activeId, 'other');
      expect(settings.connections.first.thinkingEnabled, isFalse);
      expect(settings.connections.map((c) => c.credentialId), credentials);
      expect(secure.reads, reads);
      expect(secure.writes, writes);
      final restarted = ModelSettings(secure: secure);
      addTearDown(restarted.dispose);
      await restarted.restore();
      expect(restarted.connections.first.thinkingEnabled, isFalse);
      expect(await restarted.keyFor('deepseek'), 'private-fixture');
      await settings.setThinkingEnabled('deepseek', null);
      expect(settings.connections.first.thinkingEnabled, isNull);
    },
  );

  test(
    'failed thinking persistence keeps the previous value and queue recovers',
    () async {
      final preferences = FailingPreferences();
      SharedPreferencesStorePlatform.instance = preferences;
      final settings = ModelSettings();
      addTearDown(settings.dispose);
      await settings.save(config(thinking: true), 'fixture-key');
      final prefs = await SharedPreferences.getInstance();
      final previous = prefs.getString('skivu.models.v1');
      preferences.failNext = true;
      final update = settings.setThinkingEnabled('deepseek', false);
      expect(settings.thinkingUpdatePending, isTrue);
      await expectLater(update, throwsStateError);
      expect(settings.thinkingUpdatePending, isFalse);
      expect(settings.active!.thinkingEnabled, isTrue);
      expect(prefs.getString('skivu.models.v1'), previous);
      await settings.setThinkingEnabled('deepseek', false);
      expect(settings.active!.thinkingEnabled, isFalse);
    },
  );

  test(
    'thinking remains pending throughout queued concurrent persistence',
    () async {
      final preferences = DelayedPreferences();
      SharedPreferencesStorePlatform.instance = preferences;
      final settings = ModelSettings();
      addTearDown(settings.dispose);
      await settings.save(config(thinking: true), 'fixture-key');
      final firstGate = Completer<void>(), secondGate = Completer<void>();
      preferences.gates.addAll([firstGate, secondGate]);
      final notifications = <bool>[];
      settings.addListener(
        () => notifications.add(settings.thinkingUpdatePending),
      );
      final first = settings.setThinkingEnabled('deepseek', false);
      final second = settings.setThinkingEnabled('deepseek', true);
      expect(settings.thinkingUpdatePending, isTrue);
      expect(settings.active!.thinkingEnabled, isTrue);
      firstGate.complete();
      await first;
      expect(settings.active!.thinkingEnabled, isFalse);
      expect(settings.thinkingUpdatePending, isTrue);
      secondGate.complete();
      await second;
      expect(settings.active!.thinkingEnabled, isTrue);
      expect(settings.thinkingUpdatePending, isFalse);
      expect(notifications.first, isTrue);
      expect(notifications.last, isFalse);
    },
  );
}

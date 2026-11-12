import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ski/assistant_engine.dart';
import 'package:ski/cloud_conversations.dart';
import 'package:ski/device_engine.dart';
import 'package:ski/state.dart';
import 'package:ski/tool_submission.dart';

import 'real_chat_store_test.dart' show MemoryChats, TestModels;

const receiptPrefix = '真实工具回执（数据）：';

Map<String, dynamic> receiptMessage(Map<String, String> message) =>
    Map<String, dynamic>.from(
      jsonDecode(message['content']!.substring(receiptPrefix.length)),
    );

String call(String tool, [Map<String, dynamic> arguments = const {}]) =>
    jsonEncode({
      'type': 'call',
      'tool': tool,
      'arguments': arguments,
      'message': 'fixture operation',
    });

const finish = '{"type":"final","message":"fixture complete"}';

DeviceEngine native(
  Future<Map<String, dynamic>> Function(Map<String, dynamic>) invoke,
) => DeviceEngine(
  transport: (method, arguments) async => method == 'status'
      ? {'enabled': true, 'system': true, 'control': true}
      : invoke(arguments),
);

class LargeReads implements AssistantExtensions {
  final payloads = {
    'a': 'payload-a-${'x' * 8000}',
    'b': 'payload-b-${'y' * 9000}',
  };

  @override
  Future<List<Map<String, dynamic>>> catalog() async => [
    for (final key in payloads.keys)
      {
        'id': 'coding.fixture.$key',
        'effect': 'read',
        'parameters': {
          'type': 'object',
          'properties': <String, dynamic>{},
          'required': <String>[],
          'additionalProperties': false,
        },
      },
  ];

  @override
  Future<DeviceToolReceipt> invoke(
    String tool,
    Map<String, dynamic> arguments,
    String requestId,
    void Function() check,
  ) async => DeviceToolReceipt({
    'tool': tool,
    'requestId': requestId,
    'outcome': 'verified',
    'summary': 'fixture read',
    'value': {'payload': payloads[tool.split('.').last]},
  });

  @override
  Future<Map<String, dynamic>> cancel() async => {'outcome': 'cancelled'};
}

class CountingChats extends MemoryChats {
  int writes = 0;
  @override
  Future<void> write(String value) async {
    writes++;
    await super.write(value);
  }
}

class PhaseEngine extends AssistantEngine {
  PhaseEngine()
    : super(
        identity: () => 'fixture',
        model: (_, __) async => finish,
        read: () async => null,
        write: (_) async {},
      ) {
    account = 'fixture';
  }

  void publishPhase(String value) {
    phase = value;
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'workflow model projection keeps each child once and full history survives restart',
    () async {
      final tools = LargeReads();
      var round = 0, parentIndex = -1;
      String? saved;
      late AssistantEngine engine;
      engine = AssistantEngine(
        identity: () => 'fixture',
        read: () async => null,
        write: (raw) async => saved = raw,
        engine: native(
          (_) async => throw StateError('No native action expected'),
        ),
        extensions: tools,
        model: (_, history) async {
          round++;
          if (round == 1) {
            return call('workflow.batch', {
              'steps': [
                for (final key in tools.payloads.keys)
                  {'id': key, 'tool': 'coding.fixture.$key', 'arguments': {}},
              ],
            });
          }
          if (round == 2) {
            for (final payload in tools.payloads.values) {
              expect(
                history.where(
                  (message) => message['content']!.contains(payload),
                ),
                hasLength(1),
              );
            }
            final parent = history
                .where(
                  (message) => message['content']!.startsWith(receiptPrefix),
                )
                .map(receiptMessage)
                .singleWhere((receipt) => receipt['tool'] == 'workflow.batch');
            final value = parent['value'] as Map;
            expect(
              (value['steps'] as List).every(
                (step) => !(step as Map).containsKey('receipt'),
              ),
              isTrue,
            );
            parentIndex = value['historyReference']['index'] as int;
            expect(value['historyReference']['tool'], 'workflow.history.read');
            final original = receiptMessage(engine.context[parentIndex]);
            expect(
              original['value']['steps'][0]['receipt']['value']['payload'],
              tools.payloads['a'],
            );
            expect(
              original['value']['steps'][1]['receipt']['value']['payload'],
              tools.payloads['b'],
            );
            return call('workflow.history.read', {'index': parentIndex});
          }
          final fullRead = receiptMessage(history.last);
          expect(
            fullRead['value']['text'],
            engine.context[parentIndex]['content'],
          );
          return finish;
        },
      );
      addTearDown(engine.dispose);
      await engine.send('run fixture reads');
      expect(engine.phase, 'done');
      expect(engine.modelHistoryMetrics['workflowParentsProjected'], 1);
      expect(
        engine.modelHistoryMetrics['removedCharacters'],
        greaterThan(15000),
      );
      final lastSnapshot = jsonDecode(saved!) as Map;
      expect(
        lastSnapshot['journalPersistence']['scope'],
        'measured_before_this_snapshot',
      );
      expect(
        lastSnapshot['modelHistoryProjection']['workflowParentsProjected'],
        1,
      );
      final restored = AssistantEngine(
        identity: () => 'fixture',
        read: () async => saved,
        write: (_) async {},
        model: (_, __) async =>
            throw StateError('No model call during restore'),
      );
      addTearDown(restored.dispose);
      await restored.restore();
      expect(restored.context[parentIndex], engine.context[parentIndex]);
      expect(jsonEncode(restored.workflows), jsonEncode(engine.workflows));
    },
  );

  test('ordinary reads do not save unchanged submissions', () async {
    var round = 0, fenceSaves = 0;
    final engine = AssistantEngine(
      identity: () => 'fixture',
      read: () async => null,
      write: (_) async {},
      persistToolSubmissions: () async => fenceSaves++,
      engine: native(
        (arguments) async => {
          'requestId': arguments['requestId'],
          'outcome': 'verified',
          'value': {'level': 80},
        },
      ),
      model: (_, __) async =>
          ++round < 3 ? call('settings.brightness.read') : finish,
    );
    addTearDown(engine.dispose);
    await engine.send('read fixture');
    expect(engine.phase, 'done');
    expect(fenceSaves, 0);
  });

  test(
    'external dispatch retains prepared fence and checkpoints before invoking',
    () async {
      var round = 0, fenceSaves = 0, invokes = 0;
      String? saved;
      late AssistantEngine engine;
      engine = AssistantEngine(
        identity: () => 'fixture',
        read: () async => null,
        write: (raw) async => saved = raw,
        persistToolSubmissions: () async {
          fenceSaves++;
        },
        engine: native((arguments) async {
          invokes++;
          expect(fenceSaves, 1);
          expect(engine.toolSubmissions.single.outcome, 'prepared');
          final checkpoint = jsonDecode(saved!) as Map;
          expect(checkpoint['pending']['requestId'], arguments['requestId']);
          expect(
            checkpoint['deviceCalls'].containsKey(arguments['requestId']),
            isTrue,
          );
          return {'requestId': arguments['requestId'], 'outcome': 'verified'};
        }),
        model: (_, __) async => ++round == 1
            ? call('clock.alarm.create', {'hour': 7, 'minute': 30})
            : finish,
      );
      addTearDown(engine.dispose);
      await engine.send('create fixture alarm');
      expect(engine.phase, 'done');
      expect(invokes, 1);
      expect(fenceSaves, 2);
      expect(engine.toolSubmissions.single.outcome, 'verified');
    },
  );

  test('read verification persists a changed fence only once', () async {
    var round = 0, fenceSaves = 0;
    late AssistantEngine engine;
    engine = AssistantEngine(
      identity: () => 'fixture',
      read: () async => null,
      write: (_) async {},
      persistToolSubmissions: () async => fenceSaves++,
      engine: native(
        (arguments) async => {
          'requestId': arguments['requestId'],
          'outcome': 'verified',
          'value': {'verifiedRequestId': 'fixture-original'},
        },
      ),
      model: (_, __) async {
        round++;
        if (round == 1) {
          engine.toolSubmissions.add(
            ToolSubmission(
              fingerprint: 'a' * 64,
              taskId: engine.taskId,
              requestId: 'fixture-original',
              outcome: 'dispatched',
              tool: 'ui.tap',
            ),
          );
        }
        if (round < 3)
          return call('ui.verify', {
            'requestId': 'fixture-original',
            'expect': {'kind': 'navigation', 'text': 'new page'},
          });
        return finish;
      },
    );
    addTearDown(engine.dispose);
    await engine.send('open fixture settings');
    expect(engine.phase, 'done');
    expect(engine.toolSubmissions.single.outcome, 'verified');
    expect(fenceSaves, 1);
  });

  test(
    'phase publications do not save chats while new transcript messages do',
    () async {
      final disk = CountingChats();
      final store = DemoStore(settings: TestModels(), storage: disk);
      addTearDown(store.dispose);
      await store.restore();
      final engine = PhaseEngine();
      addTearDown(engine.dispose);
      final coordinator = CloudChatCoordinator(
        store,
        engineFactory: (_) => engine,
      );
      coordinator.attach();
      final chat = store.conversations.first;
      coordinator.engineFor(chat);
      await store.saveChats();
      final before = disk.writes;
      for (final phase in ['thinking', 'executing', 'paused']) {
        engine.publishPhase(phase);
      }
      await Future<void>.delayed(Duration.zero);
      expect(disk.writes, before);
      engine.messages.add({
        'role': 'assistant',
        'content': 'fixture transcript',
      });
      engine.publishPhase('done');
      await store.saveChats();
      expect(disk.writes, greaterThan(before));
      expect(chat.messages.last.text, 'fixture transcript');
    },
  );

  test(
    'journal timing tracks queued failures and recovers without extra writes',
    () async {
      final gate = Completer<void>();
      var writes = 0;
      final engine = AssistantEngine(
        identity: () => 'fixture',
        read: () async => null,
        model: (_, __) async => finish,
        write: (_) async {
          writes++;
          if (writes == 1) await gate.future;
          if (writes == 2) throw StateError('fixture disk full');
        },
      );
      addTearDown(engine.dispose);
      final first = engine.save();
      final second = engine.save();
      final failed = expectLater(second, throwsStateError);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      gate.complete();
      await first;
      await failed;
      await engine.save();
      expect(writes, 3);
      final metrics = engine.workspaceSnapshot['journalPersistence'] as Map;
      expect(metrics['scope'], 'current_process');
      expect(metrics['saveCount'], 3);
      expect(metrics['failedWrites'], 1);
      expect(metrics['queueUs'], greaterThan(0));
      expect(metrics['writeUs'], greaterThan(0));
    },
  );
}

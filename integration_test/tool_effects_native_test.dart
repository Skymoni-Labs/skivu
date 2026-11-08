import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ski/main.dart' as app;
import 'package:ski/state.dart';
import 'package:ski/model_connection.dart';
import 'package:ski/cloud_conversations.dart';
import 'package:ski/device_engine.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'new goals, result confirmation and repeat guard with zero real effects',
    (tester) async {
      expect(const bool.fromEnvironment('SKIVU_ENGINE_QA'), true);
      await app.main();
      for (var i = 0; i < 16; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      final oldConnection = demo.models.activeId;
      final oldAccount = demo.useAccount, oldBeta = demo.useBeta;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var effects = 0, requests = 0;
      // Receipts are controlled at the platform boundary. No alarm or other real
      // external operation is invoked on Android, including during repeat tests.
      messenger.setMockMethodCallHandler(DeviceEngine.channel, (call) async {
        switch (call.method) {
          case 'status':
            return {'enabled': true, 'system': true};
          case 'effect.lookup':
            return {'found': false};
          case 'session.start':
          case 'session.end':
            return {};
          case 'cancelRequest':
            return {'outcome': 'cancelled'};
          case 'invoke':
            effects++;
            return {
              'requestId': (call.arguments as Map)['requestId'],
              'outcome': 'dispatched',
              'summary': '验收模拟：请求已交给目标软件。',
            };
          default:
            throw StateError('Unexpected platform method ${call.method}');
        }
      });
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        await utf8.decoder.bind(request).join();
        requests++;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'content': jsonEncode(
                    requests <= 2
                        ? {
                            'type': 'call',
                            'tool': 'clock.alarm.create',
                            'arguments': {'hour': 7, 'minute': 15},
                            'message': '验收模拟设置闹钟',
                          }
                        : {'type': 'final', 'message': '新的话题正常回复，旧操作没有再次执行。'},
                  ),
                },
              },
            ],
          }),
        );
        await request.response.close();
      });
      final connection = ModelConnection(
        id: 'effect-local-qa',
        name: '本地受控验收',
        provider: '本地受控验收',
        protocol: ApiProtocol.chat,
        address: 'http://127.0.0.1:${server.port}/v1',
        model: 'controlled-no-real-effects',
        auth: 'none',
        streaming: false,
      );
      Future<void> settleReply() async {
        for (var i = 0; i < 180 && demo.streaming; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(demo.streaming, false);
        await tester.pump(const Duration(milliseconds: 350));
      }

      Future<void> frame(String name) async {
        debugPrint('EXECUTION_REVIEW_FRAME $name');
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(seconds: 2)),
        );
      }

      try {
        demo.models.connections.add(connection);
        demo.models.activeId = connection.id;
        demo.useAccount = false;
        demo.useBeta = false;
        demo.newChat(personaId: cloudPersonaId);
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 200));
        }
        final field = find.byKey(const ValueKey('chat-composer-field'));
        Future<void> send(String text) async {
          // Keep IME animations outside this receipt/state-machine acceptance.
          // The real composer controller and send button still handle the goal.
          tester.widget<TextField>(field).controller!.text = text;
          await tester.pump(const Duration(milliseconds: 350));
          await tester.tap(find.byTooltip('发送消息'));
          await tester.pump(const Duration(milliseconds: 100));
          expect(
            demo.messages.where((m) => m.user).last.text,
            text,
            reason: 'Composer must submit the new user goal: ${demo.lastError}',
          );
          await settleReply();
        }

        await send('验收模拟：设置7点15分闹钟。');
        expect(effects, 1);
        expect(requests, 1);
        expect(
          cloudChats.engineFor(demo.conversations[demo.conversation]).phase,
          'awaiting_verification',
        );
        final confirm = find.text('已确认任务完成');
        expect(confirm, findsOneWidget);
        await tester.ensureVisible(confirm);
        await frame('collapsed');
        await tester.tap(confirm);
        // Confirmation persists to the real Android chat archive before updating
        // its canonical messages; virtual frame time cannot complete that I/O.
        for (
          var i = 0;
          i < 100 && !demo.messages.last.text.contains('按你的确认');
          i++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(effects, 1);
        expect(demo.messages.last.text, contains('按你的确认'));
        expect(find.textContaining('按你的确认'), findsOneWidget);
        await frame('expanded');
        await send('我们换个话题。'); // Model deliberately emits the stale alarm plan.
        expect(effects, 1);
        expect(requests, 2);
        expect(
          cloudChats.engineFor(demo.conversations[demo.conversation]).phase,
          'confirmation',
        );
        expect(find.text('确认再次执行此操作'), findsWidgets);
        await frame('recollapsed');
        await send('不执行旧操作，聊新的。');
        expect(effects, 1);
        expect(requests, 3);
        expect(demo.messages.last.text, contains('旧操作没有再次执行'));
        expect(tester.takeException(), isNull);
        binding.reportData = {
          'passed': true,
          'transport': 'loopback model + controlled native receipts',
          'realAndroidUi': true,
          'actualExternalToolCalls': 0,
          'simulatedEffects': effects,
          'localModelRequests': requests,
          'paidModelCalls': 0,
          'confirmationDispatches': 0,
          'stalePlanBlocked': true,
          'freshTopicCancelsPending': true,
          'confirmedByUserNotDevice': true,
        };
      } finally {
        if (demo.streaming) demo.stop();
        demo.models.connections.removeWhere((c) => c.id == connection.id);
        demo.models.activeId = oldConnection;
        demo.useAccount = oldAccount;
        demo.useBeta = oldBeta;
        demo.changed();
        await demo.saveChats();
        messenger.setMockMethodCallHandler(DeviceEngine.channel, null);
        await server.close(force: true);
      }
    },
  );
}

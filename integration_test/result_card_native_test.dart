import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ski/main.dart' as app;
import 'package:ski/state.dart';
import 'package:ski/appearance.dart';
import 'package:ski/model_connection.dart';
import 'package:ski/cloud_conversations.dart';
import 'package:ski/device_engine.dart';
import 'package:ski/task_result_card.dart';
import 'package:ski/thinking_disclosure.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('result card and native navigation with streamed text and reasoning', (
    tester,
  ) async {
    expect(const bool.fromEnvironment('SKIVU_ENGINE_QA'), true);
    await app.main();
    for (var i = 0; i < 16; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    final before = await deviceEngine.status();
    final oldConnection = demo.models.activeId;
    final oldAccount = demo.useAccount, oldBeta = demo.useBeta;
    final showThinking = appearance.flag('showThinking');
    appearance.set('showThinking', true);
    await deviceEngine.configure(
      enabled: before['enabled'] == true,
      system: before['system'] == true,
      control: before['control'] == true,
      shell: before['shell'] == true,
      packages: {
        ...List<String>.from(before['packages'] as List? ?? []),
        'com.android.deskclock',
      }.toList(),
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var effects = 0, requests = 0, opens = 0;
    var allStreamingRequests = true;
    var expectedTool = true, expectedTarget = true;
    late Future<Object?> Function(MethodCall) host;
    host = (call) async {
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
          expectedTool =
              expectedTool &&
              (call.arguments as Map)['tool'] == 'clock.timer.start';
          return {
            'requestId': (call.arguments as Map)['requestId'],
            'outcome': 'verified',
            'summary': '受控验收回执：计时器登记成功。',
          };
        case 'result.open':
          opens++;
          expectedTarget =
              expectedTarget &&
              (call.arguments as Map)['target'] == 'clock.timers';
          // Only this explicit button uses the real native navigation handler.
          messenger.setMockMethodCallHandler(DeviceEngine.channel, null);
          try {
            return await DeviceEngine.channel.invokeMapMethod<String, dynamic>(
              call.method,
              call.arguments,
            );
          } finally {
            messenger.setMockMethodCallHandler(DeviceEngine.channel, host);
          }
        default:
          throw StateError('Unexpected host method ${call.method}');
      }
    };
    messenger.setMockMethodCallHandler(DeviceEngine.channel, host);
    final finalStarted = Completer<void>(), releaseFinal = Completer<void>();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
      allStreamingRequests = allStreamingRequests && body['stream'] == true;
      requests++;
      request.response.bufferOutput = false;
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
        charset: 'utf-8',
      );
      void delta(Map<String, String> data) => request.response.write(
        'data: ${jsonEncode({
          'choices': [
            {'delta': data},
          ],
        })}\n\n',
      );
      if (requests == 1) {
        delta({'reasoning_content': '先检查手机时钟的操作结果。'});
        delta({
          'content': jsonEncode({
            'type': 'call',
            'tool': 'clock.timer.start',
            'arguments': {'seconds': 600, 'label': '10分钟闹钟'},
            'message': '设置10分钟提醒',
          }),
        });
      } else {
        request.response.write(': ${List.filled(4096, ' ').join()}\n\n');
        await request.response.flush();
        delta({'reasoning_content': '已取得回执，整理回复。'});
        delta({'content': '{"type":"final","message":"已设置'});
        await request.response.flush();
        debugPrint('RESULT_CARD_SERVER_FLUSH');
        finalStarted.complete();
        await releaseFinal.future;
        delta({'content': '10分钟提醒。"}'});
      }
      request.response.write('data: [DONE]\n\n');
      await request.response.close();
    });
    final connection = ModelConnection(
      id: 'result-card-local-qa',
      name: '本地卡片验收',
      provider: '本地验收',
      protocol: ApiProtocol.chat,
      address: 'http://127.0.0.1:${server.port}/v1',
      model: 'local-stream-card',
      auth: 'none',
      streaming: true,
    );
    Future<void> poll(bool Function() check) async {
      for (var i = 0; i < 240 && !check(); i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      if (!check()) {
        final chat = demo.conversations[demo.conversation];
        debugPrint(
          'RESULT_CARD_DIAGNOSTIC requests=$requests effects=$effects started=${finalStarted.isCompleted} phase=${cloudChats.engineFor(chat).phase} streaming=${demo.streaming} messages=${jsonEncode(chat.messages.map((m) => {'text': m.text, 'status': m.status, 'thinking': m.thinking}).toList())}',
        );
      }
      expect(check(), true);
    }

    Future<void> frame(String name) async {
      debugPrint('RESULT_CARD_FRAME $name');
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
      await tester.pump(const Duration(milliseconds: 400));
      final field = find.byKey(const ValueKey('chat-composer-field'));
      tester.widget<TextField>(field).controller!.text = '验收：设置10分钟闹钟。';
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.byTooltip('发送消息'));
      await poll(
        () => finalStarted.isCompleted && demo.messages.last.text == '已设置',
      );
      expect(demo.streaming, true);
      expect(find.byType(TaskResultCard), findsNothing);
      expect(find.byType(ThinkingDisclosure), findsOneWidget);
      await frame('streaming');
      releaseFinal.complete();
      await poll(() => !demo.streaming);
      expect(find.byType(TaskResultCard), findsOneWidget);
      expect(find.text('10分钟闹钟'), findsOneWidget);
      expect(find.text('已设置10分钟提醒。'), findsOneWidget);
      expect(opens, 0);
      expect(effects, 1);
      expect(allStreamingRequests, true);
      expect(expectedTool, true);
      final chat = demo.conversations[demo.conversation];
      final tool = chat.messages.firstWhere((m) => m.toolReceipt);
      final avatar = find.byKey(ValueKey('execution-avatar-${tool.id}'));
      // Finish the normal post-reply bottom-follow animation before testing
      // whether a separate disclosure action moves the avatar.
      await tester.pump(const Duration(milliseconds: 500));
      await frame('completed');
      final position = tester.getTopLeft(avatar);
      final viewport = tester
          .state<ScrollableState>(
            find.ancestor(of: avatar, matching: find.byType(Scrollable)).first,
          )
          .position;
      final beforeScroll = viewport.pixels;
      await tester.tap(find.byKey(const ValueKey('thinking-toggle')));
      await tester.pump(const Duration(milliseconds: 400));
      if (tester.getTopLeft(avatar) != position)
        debugPrint(
          'RESULT_CARD_AVATAR before=$position after=${tester.getTopLeft(avatar)} scrollBefore=$beforeScroll scrollAfter=${viewport.pixels}',
        );
      expect(tester.getTopLeft(avatar), position);
      expect(find.textContaining('先检查手机时钟'), findsOneWidget);
      await frame('thinking');
      final open = find.descendant(
        of: find.byType(TaskResultCard),
        matching: find.text('打开'),
      );
      await tester.ensureVisible(open);
      debugPrint('RESULT_CARD_OPEN_START');
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 1)),
      );
      await tester.tap(open);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 6)),
      );
      expect(opens, 1);
      expect(expectedTarget, true);
      expect(effects, 1);
      await tester.pump(const Duration(milliseconds: 300));
      expect(cloudChats.engineFor(chat).phase, 'done');
      expect(tester.takeException(), isNull);
      binding.reportData = {
        'passed': true,
        'realAndroidUi': true,
        'streamingPrefixBeforeEof': true,
        'reasoningVisible': true,
        'avatarStationary': true,
        'completionCardAfterReply': true,
        'openNavigationCalls': opens,
        'simulatedEffects': effects,
        'actualExternalMutations': 0,
        'realNativeClockNavigation': true,
        'localModelRequests': requests,
        'paidModelCalls': 0,
        'phoneTargeted': false,
      };
    } finally {
      if (!releaseFinal.isCompleted) releaseFinal.complete();
      if (demo.streaming) demo.stop();
      messenger.setMockMethodCallHandler(DeviceEngine.channel, null);
      await deviceEngine.configure(
        enabled: before['enabled'] == true,
        system: before['system'] == true,
        control: before['control'] == true,
        shell: before['shell'] == true,
        packages: List<String>.from(before['packages'] as List? ?? []),
      );
      demo.models.connections.removeWhere((c) => c.id == connection.id);
      demo.models.activeId = oldConnection;
      demo.useAccount = oldAccount;
      demo.useBeta = oldBeta;
      appearance.set('showThinking', showThinking);
      demo.changed();
      await demo.saveChats();
      await server.close(force: true);
    }
  });
}

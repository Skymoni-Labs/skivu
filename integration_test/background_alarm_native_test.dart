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
    'real native scheduling stays headless through chat and stale plans',
    (tester) async {
      expect(const bool.fromEnvironment('SKIVU_ENGINE_QA'), true);
      await app.main();
      for (var i = 0; i < 16; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      final before = await deviceEngine.status();
      expect(
        before['alarmReady'],
        true,
        reason:
            'Only the isolated QA package must be configured before this test',
      );
      await deviceEngine.configure(
        enabled: true,
        system: true,
        control: false,
        shell: false,
        packages: [],
      );
      final oldConnection = demo.models.activeId;
      final oldAccount = demo.useAccount, oldBeta = demo.useBeta;
      final label = 'qa-headless-ui-${DateTime.now().microsecondsSinceEpoch}';
      final due = DateTime.now().add(const Duration(hours: 2));
      final args = {
        'hour': due.hour,
        'minute': due.minute,
        'label': label,
        'vibrate': false,
      };
      var requests = 0;
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
                    requests == 1 || requests == 3
                        ? {
                            'type': 'call',
                            'tool': 'assistant.alarm.create',
                            'arguments': args,
                            'message': '登记小云后台闹钟',
                          }
                        : {
                            'type': 'final',
                            'message': requests >= 5
                                ? '新的话题正常回复，没有继续旧任务。'
                                : '小云闹钟已登记，由小云提醒，设置过程没有打开系统时钟。',
                          },
                  ),
                },
              },
            ],
          }),
        );
        await request.response.close();
      });
      final connection = ModelConnection(
        id: 'headless-local-qa',
        name: '本地后台验收',
        provider: '本地后台验收',
        protocol: ApiProtocol.chat,
        address: 'http://127.0.0.1:${server.port}/v1',
        model: 'headless-native-qa',
        auth: 'none',
        streaming: false,
      );
      Future<void> frame(String name) async {
        debugPrint('BACKGROUND_REVIEW_FRAME $name');
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
        Future<void> send(String text) async {
          tester
                  .widget<TextField>(
                    find.byKey(const ValueKey('chat-composer-field')),
                  )
                  .controller!
                  .text =
              text;
          await tester.pump(const Duration(milliseconds: 350));
          await tester.tap(find.byTooltip('发送消息'));
          await tester.pump(const Duration(milliseconds: 100));
          expect(demo.messages.where((m) => m.user).last.text, text);
          for (var i = 0; i < 240 && demo.streaming; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 50)),
            );
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(demo.streaming, false);
          await tester.pump(const Duration(milliseconds: 350));
        }

        debugPrint('BACKGROUND_REVIEW_START');
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(seconds: 1)),
        );
        await send('验收：设置一个小云闹钟，不打开手机时钟。');
        expect(requests, 2);
        final chat = demo.conversations[demo.conversation];
        expect(cloudChats.engineFor(chat).phase, 'done');
        expect(cloudChats.engineFor(chat).canConfirmResult, false);
        expect(find.text('已确认任务完成'), findsNothing);
        var owned = (await deviceEngine.alarms())
            .where((item) => item['label'] == label && item['enabled'] == true)
            .toList();
        expect(owned, hasLength(1));
        final id = owned.single['id'];
        final firstDue = owned.single['nextAt'];
        await frame('scheduled');
        await send(
          '换一个话题。',
        ); // Loopback model deliberately repeats the old plan.
        owned = (await deviceEngine.alarms())
            .where((item) => item['label'] == label && item['enabled'] == true)
            .toList();
        expect(owned, hasLength(1));
        expect(owned.single['id'], id);
        expect(owned.single['nextAt'], firstDue);
        expect(cloudChats.engineFor(chat).phase, 'done');
        expect(find.text('确认再次执行此操作'), findsNothing);
        await frame('reused');
        await send('聊新的内容。');
        expect(requests, 5);
        expect(demo.messages.last.text, contains('没有继续旧任务'));
        expect(tester.takeException(), isNull);
        await frame('new-topic');
        debugPrint('BACKGROUND_REVIEW_END');
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(seconds: 1)),
        );
        binding.reportData = {
          'passed': true,
          'transport': 'loopback model + real native AlarmManager',
          'nativeChannelMocked': false,
          'realAndroidUi': true,
          'uniqueAlarmResources': 1,
          'stalePlanReusedSameResource': true,
          'manualConfirmationRequired': false,
          'newTopicWorks': true,
          'localModelRequests': requests,
          'paidModelCalls': 0,
        };
      } finally {
        if (demo.streaming) demo.stop();
        for (final item in await deviceEngine.alarms()) {
          if (item['label'] == label)
            await deviceEngine.cancelAlarm(item['id'] as String);
        }
        demo.models.connections.removeWhere((c) => c.id == connection.id);
        demo.models.activeId = oldConnection;
        demo.useAccount = oldAccount;
        demo.useBeta = oldBeta;
        demo.changed();
        await demo.saveChats();
        await deviceEngine.configure(
          enabled: before['enabled'] == true,
          system: before['system'] == true,
          control: before['control'] == true,
          shell: before['shell'] == true,
          packages: List<String>.from(before['packages'] as List? ?? []),
        );
        await server.close(force: true);
      }
    },
  );
}

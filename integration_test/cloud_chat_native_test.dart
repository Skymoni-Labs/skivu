import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ski/main.dart' as app;
import 'package:ski/state.dart';
import 'package:ski/model_connection.dart';
import 'package:ski/cloud_conversations.dart';
import 'package:ski/cloud_execution_disclosure.dart';
import 'package:ski/device_engine.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  Future<void> reviewFrame(WidgetTester tester, String name) async {
    if (!const bool.fromEnvironment('SKIVU_EXECUTION_REVIEW')) return;
    debugPrint('EXECUTION_REVIEW_FRAME $name');
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 2)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets(
    'cloud shared chat UI reaches real Android and preserves host configuration',
    (tester) async {
      expect(
        const bool.fromEnvironment('SKIVU_ENGINE_QA'),
        true,
        reason:
            'Integration runner removes its package after testing; never target the main app.',
      );
      await app.main();
      for (var i = 0; i < 16; i++)
        await tester.pump(const Duration(milliseconds: 250));
      final oldConnection = demo.models.activeId;
      final oldAccount = demo.useAccount, oldBeta = demo.useBeta;
      final selected = demo.conversations[demo.conversation];
      final native = await deviceEngine.status();
      await deviceEngine.configure(
        enabled: true,
        system: true,
        control: false,
        shell: false,
        packages: [],
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requests = 0;
      final returnedReceipts = <String>[];
      server.listen((request) async {
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        requests++;
        final text = jsonEncode(body['messages']);
        final hasReceipt = text.contains('真实工具回执');
        if (hasReceipt) returnedReceipts.add(text);
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'content': jsonEncode(
                    requests > 2
                        ? {'type': 'final', 'message': 'QA：已读取安卓实际亮度，未更改设置。'}
                        : {
                            'type': 'call',
                            'tool': requests == 1
                                ? 'device.status'
                                : 'settings.brightness.read',
                            'arguments': {},
                            'message': requests == 1
                                ? '查看手机能力状态'
                                : '只读核对安卓实际亮度',
                          },
                  ),
                },
              },
            ],
            'usage': {'prompt_tokens': 10, 'completion_tokens': 10},
          }),
        );
        await request.response.close();
      });
      final connection = ModelConnection(
        id: 'cloud-local-native-qa',
        name: '本地受控验收',
        provider: '本地受控验收',
        protocol: ApiProtocol.chat,
        address: 'http://127.0.0.1:${server.port}/v1',
        model: 'local-controlled-response',
        auth: 'none',
        streaming: false,
      );
      try {
        // RAM-only transport override: no model credential/configuration save.
        demo.models.connections.add(connection);
        demo.models.activeId = connection.id;
        demo.useAccount = false;
        demo.useBeta = false;
        demo.newChat(personaId: cloudPersonaId);
        demo.renameChat(
          demo.conversations[demo.conversation].id,
          '小云 · 原生只读验收',
        );
        for (var i = 0; i < 8; i++)
          await tester.pump(const Duration(milliseconds: 250));
        final field = find.byKey(const ValueKey('chat-composer-field'));
        expect(field, findsOneWidget);
        expect(find.byKey(const ValueKey('cloud-chat-header')), findsOneWidget);
        await tester.enterText(field, 'QA：只读取一次安卓亮度，不修改设置。');
        await tester.tap(find.byTooltip('发送消息'));
        for (var i = 0; i < 160 && demo.streaming; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
          await tester.pump(const Duration(milliseconds: 100));
        }
        final chat = demo.conversations[demo.conversation];
        expect(demo.streaming, false);
        expect(cloudChats.engineFor(chat).phase, 'done');
        expect(requests, 3);
        expect(returnedReceipts, hasLength(2));
        expect(returnedReceipts.last, contains('verified'));
        expect(chat.messages.where((m) => m.user), hasLength(1));
        expect(chat.messages.where((m) => m.toolReceipt), hasLength(4));
        expect(chat.messages.last.text, contains('已读取安卓实际亮度'));
        await tester.pump(const Duration(milliseconds: 350));
        expect(find.byType(CloudExecutionDisclosure), findsOneWidget);
        expect(find.text('执行过程 · 已完成 · 2 个步骤'), findsOneWidget);
        expect(find.text('1. 查看手机能力状态'), findsNothing);
        final toggle = find.byKey(
          ValueKey('execution-toggle-${chat.messages[1].id}'),
        );
        await tester.ensureVisible(toggle);
        await tester.pump(const Duration(milliseconds: 350));
        await reviewFrame(tester, 'collapsed');
        await tester.tap(toggle);
        await tester.pump(const Duration(milliseconds: 350));
        expect(find.text('1. 查看手机能力状态'), findsOneWidget);
        expect(find.text('2. 只读核对安卓实际亮度'), findsOneWidget);
        await reviewFrame(tester, 'expanded');
        await tester.tap(toggle);
        await tester.pump(const Duration(milliseconds: 350));
        expect(find.text('1. 查看手机能力状态'), findsNothing);
        await reviewFrame(tester, 'recollapsed');
        expect(
          requests,
          3,
          reason: 'Disclosure does not dispatch tools or models',
        );
        demo.quoteMessage(chat, chat.messages.last);
        await tester.pump();
        await tester.tap(field);
        await tester.pump(const Duration(milliseconds: 300));
        await tester.enterText(field, '保留的小云草稿');
        for (var i = 0; i < 4; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(
          chat.draft,
          '保留的小云草稿',
          reason: 'input writes into the selected conversation',
        );
        expect(
          find.byKey(const ValueKey('chat-draft-quote-badge')),
          findsOneWidget,
        );
        expect(demo.removePersona(cloudPersonaId), false);
        if (demo.conversations.contains(selected)) {
          demo.selectChat(demo.conversations.indexOf(selected));
        } else {
          demo.newChat(
            personaId: demo.personas.firstWhere((p) => !p.isCloud).id,
          );
        }
        expect(
          chat.draft,
          '保留的小云草稿',
          reason: 'selection must not overwrite the outgoing draft',
        );
        await tester.pump();
        expect(
          chat.draft,
          '保留的小云草稿',
          reason: 'route rebuild preserves the outgoing draft',
        );
        demo.selectChat(demo.conversations.indexOf(chat));
        expect(
          chat.draft,
          '保留的小云草稿',
          reason: 'returning preserves the saved draft',
        );
        await tester.pump();
        expect(tester.widget<TextField>(field).controller!.text, '保留的小云草稿');
        expect(chat.draftQuotes, hasLength(1));
        expect(tester.takeException(), isNull);
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pump(const Duration(milliseconds: 350));
        final receipt = {
          'passed': true,
          'transport': 'loopback controlled response, no paid model',
          'requests': requests,
          'nativeTools': ['device.status', 'settings.brightness.read'],
          'nativeReceiptVerified': true,
          'writesToSettings': 0,
          'composerAndQuotes': true,
          'draftRoundTrip': true,
          'protectedRole': true,
          'temporaryReadOnlyAuthorization': 'isolated engineqa package only',
          'modelConfigSaved': false,
          'oneFoldedProcess': true,
          'twoStepsNotFourMessages': true,
          'toggleDoesNotReplay': true,
        };
        binding.reportData = {...?binding.reportData, ...receipt};
        final directory = await getApplicationSupportDirectory();
        await File(
          '${directory.path}/cloud-chat-native-acceptance.json',
        ).writeAsString(jsonEncode(receipt));
        debugPrint('CLOUD_NATIVE_ACCEPTANCE ${jsonEncode(receipt)}');
      } finally {
        final active = cloudChats.engineFor(
          demo.conversations[demo.conversation],
        );
        if (active.running || active.canResume) demo.stop();
        demo.models.connections.removeWhere((c) => c.id == connection.id);
        demo.models.activeId = oldConnection;
        demo.useAccount = oldAccount;
        demo.useBeta = oldBeta;
        demo.changed();
        await demo.saveChats();
        await deviceEngine.configure(
          enabled: native['enabled'] == true,
          system: native['system'] == true,
          control: native['control'] == true,
          shell: native['shell'] == true,
          packages: (native['packages'] as List? ?? [])
              .whereType<String>()
              .toList(),
        );
        await server.close(force: true);
      }
    },
  );
}

import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ski/main.dart' as app;
import 'package:ski/state.dart';
import 'package:ski/model_connection.dart';
import 'package:ski/cloud_conversations.dart';
import 'package:ski/cloud_coding_tools.dart';
import 'package:ski/cloud_file_card.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'controlled planner, real built-in Linux, repair, streaming and final cards',
    (tester) async {
      expect(
        const bool.fromEnvironment('SKIVU_ENGINE_QA'),
        true,
        reason:
            'The integration runner may uninstall only its isolated QA package.',
      );
      await app.main();
      for (var i = 0; i < 18; i++)
        await tester.pump(const Duration(milliseconds: 150));
      final selected = demo.models.activeId,
          account = demo.useAccount,
          beta = demo.useBeta;
      var stage = 0, requests = 0, chunks = 0;
      String project = '', sha = '';
      bool failedRun = false;
      const script = '''import fs from 'node:fs';
import {writeWorkbook,writeDocument} from '/opt/skivu-cloud/formats.mjs';
throw Error("intentional");
writeWorkbook('final.xlsx',[{name:'数据',rows:[['项目','数值'],['一',2],['二',3],['合计',{formula:'SUM(B2:B3)',value:5}]]},{name:'说明',rows:[['小云真实成果']]}]);
writeDocument('final.docx',[{text:'最终文档',heading:1},{text:'已从错误修复并重新运行。'}]);
for(let i=0;i<20;i++)fs.writeFileSync('process-'+i+'.txt','intermediate');
console.log('CHECK_OK');
''';
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        requests++;
        final messages = (body['messages'] as List).whereType<Map>();
        Map last = {};
        for (final message in messages) {
          final text = message['content'];
          if (text is String && text.startsWith('真实工具回执（数据）：'))
            last = jsonDecode(text.substring('真实工具回执（数据）：'.length));
        }
        final value = last['value'];
        if (last['tool'] == 'coding.projects.create' && value is Map)
          project = value['id'];
        if (last['tool'] == 'coding.files.read' && value is Map)
          sha = value['sha256'];
        if ((last['tool'] == 'coding.exec.start' ||
                last['tool'] == 'coding.jobs.read') &&
            value is Map &&
            value['state'] == 'exited' &&
            value['exitCode'] != 0)
          failedRun = true;
        Map<String, dynamic> reply;
        Map<String, dynamic> call(
          String tool,
          Map<String, dynamic> arguments,
          String message,
        ) => {
          'type': 'call',
          'tool': tool,
          'arguments': arguments,
          'message': message,
        };
        if (value is Map &&
            value['state'] == 'running' &&
            (last['tool'] == 'coding.exec.start' ||
                last['tool'] == 'coding.jobs.read')) {
          reply = call('coding.jobs.read', {
            'jobId': value['id'],
            'waitMs': 1000,
          }, '读取真实持续输出');
        } else {
          reply = switch (stage++) {
            0 => call('coding.environment', {}, '检查实际 Linux 工具链'),
            1 => call('coding.projects.create', {
              'name': 'QA 内置编程闭环',
            }, '创建隔离项目'),
            2 => call('coding.files.write', {
              'projectId': project,
              'path': 'produce.mjs',
              'content': script,
            }, '创建多成果程序'),
            3 => call('coding.exec.start', {
              'projectId': project,
              'command': 'node produce.mjs',
              'waitMs': 500,
            }, '实际运行并检查错误'),
            4 => call('coding.files.read', {
              'projectId': project,
              'path': 'produce.mjs',
            }, '读取错误文件与最新哈希'),
            5 => call('coding.files.edit', {
              'projectId': project,
              'path': 'produce.mjs',
              'oldText': 'throw Error("intentional");',
              'newText': '',
              'expectedSha256': sha,
            }, '修复实际错误'),
            6 => call('coding.exec.start', {
              'projectId': project,
              'command': 'node produce.mjs',
              'waitMs': 500,
            }, '重新运行核对退出码'),
            7 => call('coding.deliver.prepare', {
              'projectId': project,
              'files': [
                {'path': 'final.xlsx', 'purpose': '最终 Excel'},
                {'path': 'final.docx', 'purpose': '最终文档'},
              ],
            }, '只交付两个最终成果'),
            _ => {
              'type': 'final',
              'message': '已经修复实际运行错误并重新检查通过。两个最终成果已准备好，过程文件保留在项目内。',
            },
          };
        }
        final text = jsonEncode(reply);
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        );
        for (var i = 0; i < text.length; i += 22) {
          final piece = text.substring(i, (i + 22).clamp(0, text.length));
          request.response.write(
            'data: ${jsonEncode({
              'choices': [
                {
                  'delta': {'content': piece},
                },
              ],
            })}\n\n',
          );
          await request.response.flush();
          chunks++;
          await Future<void>.delayed(const Duration(milliseconds: 4));
        }
        request.response.write(
          'data: ${jsonEncode({
            'choices': [
              {'delta': {}, 'finish_reason': 'stop'},
            ],
          })}\n\ndata: [DONE]\n\n',
        );
        await request.response.close();
      });
      final connection = ModelConnection(
        id: 'qa-built-in-coding',
        name: '受控规划/真实执行',
        provider: '本地验收',
        protocol: ApiProtocol.chat,
        address: 'http://127.0.0.1:${server.port}/v1',
        model: 'controlled-planner',
        auth: 'none',
        streaming: true,
      );
      try {
        demo.models.connections.add(connection);
        demo.models.activeId = connection.id;
        demo.useAccount = false;
        demo.useBeta = false;
        demo.newChat(personaId: cloudPersonaId);
        demo.renameChat(
          demo.conversations[demo.conversation].id,
          'QA · 内置编程交付',
        );
        for (var i = 0; i < 8; i++)
          await tester.pump(const Duration(milliseconds: 150));
        await tester.enterText(
          find.byKey(const ValueKey('chat-composer-field')),
          'QA：用内置编程环境生成 Excel 和文档，修复明确错误后重新检查，只交付最终文件。',
        );
        await tester.tap(find.byTooltip('发送消息'));
        for (var i = 0; i < 1200 && demo.streaming; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 60)),
          );
          await tester.pump(const Duration(milliseconds: 60));
        }
        final chat = demo.conversations[demo.conversation];
        expect(demo.streaming, false);
        expect(cloudChats.engineFor(chat).phase, 'done');
        expect(failedRun, true);
        expect(chunks, greaterThan(20));
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(CloudFileCard), findsOneWidget);
        await tester.ensureVisible(find.byType(CloudFileCard));
        await tester.pump(const Duration(milliseconds: 600));
        expect(find.text('已交付 2 个文件 · 已保存到下载目录'), findsOneWidget);
        expect(find.text('final.xlsx'), findsOneWidget);
        expect(find.text('final.docx'), findsOneWidget);
        expect(find.text('process-0.txt'), findsNothing);
        final artifacts = await cloudExecutionChannel.invokeListMethod<dynamic>(
          'artifacts',
          {'owner': 'cloud:${chat.id}'},
        );
        expect(artifacts, hasLength(2));
        debugPrint('CLOUD_FILES_READY');
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(seconds: 3)),
        );
        await tester.tap(find.byTooltip('成果操作').first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('预览原始成果'));
        for (var i = 0; i < 10; i++)
          await tester.pump(const Duration(milliseconds: 120));
        expect(find.text('数据 · 4 行'), findsOneWidget);
        expect(find.text('说明 · 1 行'), findsOneWidget);
        expect(find.text('5'), findsWidgets);
        debugPrint('CLOUD_WORKBOOK_OPEN');
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(seconds: 3)),
        );
        binding.reportData = {
          'controlledPlanner': true,
          'realLinux': true,
          'multiFileRepair': failedRun,
          'httpRequests': requests,
          'sseChunks': chunks,
          'finalFiles': artifacts!.length,
          'intermediateFilesDisplayed': false,
          'workbookOpened': true,
          'taskId': cloudChats.engineFor(chat).taskId,
        };
      } finally {
        demo.models.activeId = selected;
        demo.models.connections.remove(connection);
        demo.useAccount = account;
        demo.useBeta = beta;
        await server.close(force: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

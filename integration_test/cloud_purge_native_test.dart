import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ski/assistant_plugin_tools.dart';
import 'package:ski/open_plugin.dart';
import 'package:ski/open_plugin_lab.dart';
import 'package:ski/open_plugin_network.dart';
import 'package:ski/open_plugin_page.dart';
import 'package:ski/state.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'actual embedded SQLite and headless 小云 plugin tools',
    (tester) async {
      expect(const bool.fromEnvironment('SKIVU_PURGE_QA'), true);
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('小云插件实际运行测试'))),
      );
      final registry = OpenPluginRegistry();
      final production = OpenPluginPackage.parse(
        await rootBundle.loadString('assets/plugins/skivu-purge.skivu.json'),
      );
      final qa = jsonDecode(production.raw) as Map<String, dynamic>;
      final proofPath =
          'ui-proof-${DateTime.now().microsecondsSinceEpoch}.json';
      final harness = uiHarness.replaceAll('__PROOF_PATH__', proofPath);
      qa['files']['ui-qa.js'] = {
        'mime': 'application/javascript',
        'base64': base64Encode(utf8.encode(harness)),
      };
      final entry = utf8.decode(
        base64Decode(qa['files']['index.html']['base64']),
      );
      qa['files']['index.html']['base64'] = base64Encode(
        utf8.encode('$entry<script src="ui-qa.js"></script>'),
      );
      final package = OpenPluginPackage.parse(jsonEncode(qa));
      await registry.install(package);
      await registry.setEnabled('org.skivu.purge', true);
      final record = registry.records['org.skivu.purge']!;
      Future<Map> call(
        Map<String, dynamic> request, {
        bool readOnly = false,
        String? callId,
      }) async => Map.from(
        await invokePluginLab(
              record,
              {'request': request},
              assistant: true,
              readOnly: readOnly,
              callId: callId,
            )
            as Map,
      );
      final proofs = <String>[];
      final created = await call({
        'op': 'openEngagement',
        'name': 'Native offline fixture',
        'scope': ['127.0.0.1/32'],
      });
      expect(created['ok'], true);
      final engagement = created['engagement']['id'];
      proofs.add('actual SQLite database and embedded Node');
      final imported = await call({
        'op': 'import',
        'engagement': engagement,
        'assets': [
          {
            'ip': '127.0.0.1',
            'primary_name': 'native-fixture.local',
            'ports': [
              {'port': 8080, 'service': 'http'},
            ],
          },
        ],
      });
      expect(imported['ok'], true);
      final finding = {
        'op': 'addVuln',
        'engagement': engagement,
        'vuln': {
          'title': 'Native confirmed fixture',
          'target': '127.0.0.1',
          'severity': 'medium',
          'status': 'confirmed',
          'evidence': 'Fixture only',
        },
      };
      final a = await call(finding, callId: 'stable_native_write'),
          b = await call(finding, callId: 'stable_native_write');
      expect(a, b);
      expect(
        (await call({'op': 'vulns', 'engagement': engagement}))['items'],
        hasLength(1),
      );
      proofs.add(
        'same original request returns saved receipt without duplicate write',
      );
      await expectLater(
        call({'op': 'openEngagement', 'name': 'Read denied'}, readOnly: true),
        throwsA(isA<PluginApiError>()),
      );
      await expectLater(
        call({
          'op': 'import',
          'assets': [
            {'ip': '127.0.0.2'},
          ],
        }),
        throwsA(isA<PluginApiError>()),
      );
      proofs.add('read-only and explicit target enforcement');
      final tools = AssistantPluginTools(registry);
      expect(await tools.catalog(), hasLength(2));
      final query = await tools.invoke(
        'plugin:org.skivu.purge/query',
        {
          'request': jsonEncode({'op': 'assets', 'engagement': engagement}),
        },
        'native_query_1',
        () {},
      );
      final result = query.data['value']['result'];
      expect(result['ok'], true);
      expect(result['items'][0]['primary_name'], 'native-fixture.local');
      proofs.add(
        'actual headless Android WebView SDK -> 小云 environment -> SQLite -> assistant receipt',
      );
      final denied = await tools.invoke(
        'plugin:org.skivu.purge/query',
        {
          'request': jsonEncode({
            'op': 'openEngagement',
            'name': 'Must not create',
          }),
        },
        'native_query_denied',
        () {},
      );
      expect(denied.data['value']['result']['ok'], false);
      final report = await call({'op': 'report', 'engagement': engagement});
      expect(report['markdown'], contains('Native confirmed fixture'));
      final backup = await call({'op': 'backupExport'});
      expect(backup['backup']['files'], isNotEmpty);
      expect(
        (await call({'op': 'assets', 'engagement': engagement}))['total'],
        1,
      );
      proofs.add('SQLite close/export/reopen and actual report');
      await call({
        'op': 'addAttackFile',
        'engagement': engagement,
        'file': {
          'target': 'fixture',
          'name': 'fixture.txt',
          'content': 'native backup file',
          'evidence': 'offline fixture',
        },
      });
      final withFile = await call({'op': 'backupExport'});
      final restored = await call({
        'op': 'backupRestore',
        'backup': withFile['backup'],
      });
      expect(restored['previousPreserved'], true);
      final files = await call({'op': 'attackFiles', 'engagement': engagement});
      expect(
        (await call({
          'op': 'readAttackFile',
          'engagement': engagement,
          'id': files['items'][0]['files'][0]['id'],
        }))['content'],
        'native backup file',
      );
      proofs.add(
        'native backup restore relocates saved file paths and preserves prior revision',
      );
      // Leave the real plugin UI visible for the host's screenshot/phone-layout check.
      demo.personas.addAll(
        demo.personas.any((p) => p.id == cloudPersonaId)
            ? []
            : [createCloudPersona()],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: OpenPluginPage(
            record: record,
            registry: registry,
            initialRoleId: cloudPersonaId,
          ),
        ),
      );
      Map<String, dynamic>? uiProof;
      final stages = <String>[];
      for (var i = 0; i < 240; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        final bytes = await readPluginFile('org.skivu.purge', proofPath);
        if (bytes == null) continue;
        uiProof = Map<String, dynamic>.from(
          jsonDecode(utf8.decode(bytes)) as Map,
        );
        final stage = uiProof['stage'] as String;
        if (stages.isEmpty || stages.last != stage) {
          stages.add(stage);
          debugPrint('PURGE_UI_STAGE_$stage');
        }
        if (stage == 'done' || stage == 'error') break;
      }
      expect(uiProof?['stage'], 'done', reason: jsonEncode(uiProof));
      proofs.add(
        'actual visible React UI: apply/revoke rules, original assets, skills, roles, JSON intake and compatibility',
      );
      binding.reportData = {
        'checks': proofs,
        'engagement': engagement,
        'pluginDigest': production.digest,
        'qaUiHarnessDigest': package.digest,
        'uiProof': uiProof,
        'uiStages': stages,
        'modelRequests': 0,
        'independentDshRequired': false,
      };
      tools.dispose();
    },
    timeout: const Timeout(Duration(minutes: 15)),
  );
}

const uiHarness = r'''
(async()=>{
const delay=ms=>new Promise(r=>setTimeout(r,ms));
const stages=[];
async function mark(stage,extra={}){stages.push(stage);const value={stage,stages,...extra};const raw=unescape(encodeURIComponent(JSON.stringify(value)));await Skivu.call('fs.write',{path:'__PROOF_PATH__',base64:btoa(raw)});await delay(2500);}
async function until(test){for(let i=0;i<100;i++){if(await test())return;await delay(150);}throw Error('UI condition timed out');}
const button=text=>[...document.querySelectorAll('button,[role=button],.rt-tab')].find(b=>b.textContent.trim()===text);
const click=async text=>{await until(()=>button(text)&&!button(text).disabled);button(text).click();await delay(400);};
try{
await until(()=>button('使用小云预设'));await mark('rules');
await click('使用小云预设');await click('应用到小云');
await until(async()=>((await Skivu.call('prompt.get',{})).text||'').includes('你是小云'));await mark('applied');
await click('撤销应用');await until(async()=>!(await Skivu.call('prompt.get',{})).text);
await click('演练');await until(()=>document.body.textContent.includes('127.0.0.1'));await mark('drill',{width:innerWidth,scrollWidth:document.documentElement.scrollWidth});
await click('技能库');await until(()=>document.body.textContent.includes('redteam/active-scan.md'));await mark('skills');
await click('角色资料');await until(()=>document.body.textContent.includes('小云统一执行'));await mark('roles');
await click('录入 / 备份');await click('执行资料操作');await until(()=>document.querySelector('.result')?.textContent.includes('native-offline-fixture'));await mark('data');
await click('适配说明');await until(()=>document.body.textContent.includes('无需 DSH 补丁'));await mark('about');
if(document.documentElement.scrollWidth>innerWidth+1)throw Error('Outer page overflows phone viewport');
await mark('done',{width:innerWidth,scrollWidth:document.documentElement.scrollWidth,promptRevoked:!(await Skivu.call('prompt.get',{})).text});
}catch(e){await mark('error',{error:e.stack||e.message});}
})();
''';

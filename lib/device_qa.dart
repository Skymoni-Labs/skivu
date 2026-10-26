// SPDX-License-Identifier: GPL-3.0-only
// Isolated test entrypoint: fixed planning, real IPC and real Android UI input.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'device_task.dart';
import 'open_plugin.dart';
import 'open_plugin_page.dart';
import 'model_connection.dart';
import 'model_settings.dart';
import 'open_plugin_device.dart';
import 'open_plugin_runtime.dart';
import 'state.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(home: DeviceQa()));
}

class DeviceQa extends StatefulWidget {
  const DeviceQa({super.key});
  @override
  State<DeviceQa> createState() => _DeviceQaState();
}

class _DeviceQaState extends State<DeviceQa> {
  static const native = MethodChannel('skivu/device_tasks');
  String? connection;
  String status = '隔离 QA：固定规划器，真实设备执行';
  final entries = <Map<String, dynamic>>[];
  DeviceTaskRunner? runner;
  Completer<void>? safetyConfirmation;
  String? safetyCapability;
  @override
  void initState() {
    super.initState();
    native.setMethodCallHandler((call) async {
      if (call.method == 'stop' || call.method == 'serviceStopped') {
        await runner?.cancel();
      }
      if (call.method == 'deviceEvent' &&
          safetyConfirmation != null &&
          !safetyConfirmation!.isCompleted) {
        final event = jsonDecode(call.arguments as String) as Map;
        if (event['taskCapability'] == safetyCapability)
          safetyConfirmation!.complete();
      }
    });
  }

  Future<void> openPlugin({bool waitOnly = false}) async {
    try {
      modelSettings.connections.clear();
      modelSettings.connections.add(
        const ModelConnection(
          id: 'isolated-device-model',
          name: 'Fixed QA model (no real inference)',
          provider: 'Ollama',
          protocol: ApiProtocol.chat,
          address: 'http://10.0.2.2:8857/v1',
          model: 'device-fixed-planner',
          auth: 'none',
          streaming: false,
        ),
      );
      modelSettings.activeId = 'isolated-device-model';
      deviceTasks = OpenPluginDeviceTasks(
        plannerForTesting: (observation, receipts) async {
          if (waitOnly) {
            await Future<void>.delayed(const Duration(seconds: 30));
            return jsonEncode({
              'done': false,
              'summary': '等待停止/撤销验收',
              'action': 'wait',
              'arguments': {'timeout_ms': 5000},
              'evidenceIds': [],
            });
          }
          final nodes = ((observation['tree'] as Map)['elements'] as List)
              .cast<Map>();
          final saved = nodes
              .where(
                (n) => (n['text'] ?? '').toString().contains(
                  '已保存：你好，Skivu 真实插件测试',
                ),
              )
              .firstOrNull;
          if (saved != null)
            return jsonEncode({
              'done': true,
              'summary': '已在隔离便签中填写、保存并读回内容。',
              'action': '',
              'arguments': {},
              'evidenceIds': [saved['element_id']],
            });
          final editor = nodes.firstWhere(
            (n) => n['editable'] == true && n['password'] != true,
          );
          if (editor['text'] != '你好，Skivu 真实插件测试')
            return jsonEncode({
              'done': false,
              'summary': '填写测试便签',
              'action': 'input_text',
              'arguments': {
                'element_id': editor['element_id'],
                'text': '你好，Skivu 真实插件测试',
                'mode': 'replace',
              },
              'evidenceIds': [],
            });
          final button = nodes.firstWhere((n) => n['text'] == '保存便签');
          return jsonEncode({
            'done': false,
            'summary': '保存测试便签',
            'action': 'tap',
            'arguments': {'element_id': button['element_id']},
            'evidenceIds': [],
          });
        },
      );
      final raw = await File(
        '/data/user/0/com.skyjjgw.independent.ski.deviceqa/files/device-control.skivu.json',
      ).readAsString();
      await openPlugins.restore();
      final package = OpenPluginPackage.parse(raw);
      await openPlugins.install(package, origin: 'isolated device QA');
      if (mounted)
        await launchOpenPlugin(
          context,
          openPlugins.records[package.manifest.id]!,
        );
    } catch (e) {
      log('plugin-error', e.toString());
    }
  }

  Future<void> probes() async {
    try {
      final begin = await request('begin', {
        'allowedPackages': ['org.skivu.devicefixture'],
        'maxActions': 1,
        'timeoutMs': 30000,
      });
      final cap = begin['taskCapability'];
      if (cap == null) {
        log('policy', begin);
        return;
      }
      final forbidden = await request('call', {
        'taskCapability': cap,
        'name': 'launch_app',
        'arguments': {
          'request_id': 'scope-probe',
          'package_name': 'com.android.settings',
        },
      });
      final read = await request('call', {
        'taskCapability': cap,
        'name': 'observe',
        'arguments': {'mode': 'tree'},
      });
      final unknown = await request('call', {
        'taskCapability': 'wrong-task',
        'name': 'observe',
        'arguments': {'mode': 'tree'},
      });
      await request('end', {'taskCapability': cap});
      log('policy-probes', {
        'foreignLaunch': forbidden['error'],
        'foreignRead': read['error'],
        'wrongCapability': unknown['error'],
      });
      await File(
        '/data/user/0/com.skyjjgw.independent.ski.deviceqa/files/device-policy-result.json',
      ).writeAsString(jsonEncode(entries));
    } catch (e) {
      log('policy-error', e.toString());
    }
  }

  Future<void> safety() async {
    try {
      await native.invokeMethod('startService', {'taskId': 'device_safety_qa'});
      final begin = await request('begin', {
        'allowedPackages': ['org.skivu.devicefixture'],
        'maxActions': 8,
        'timeoutMs': 120000,
      });
      safetyCapability = begin['taskCapability'] as String;
      Future<Map<String, dynamic>> call(
        String name,
        Map<String, dynamic> args,
      ) => request('call', {
        'taskCapability': safetyCapability,
        'name': name,
        'arguments': args,
      });
      Future<Map<String, dynamic>> settled(
        Map<String, dynamic> result,
        String id,
      ) async {
        for (
          var i = 0;
          i < 100 && {'accepted', 'executing'}.contains(result['state']);
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          final status = await call('get_status', {'request_id': id});
          result = Map<String, dynamic>.from(
            status['request'] as Map? ?? status,
          );
        }
        return result;
      }

      await settled(
        await call('launch_app', {
          'request_id': 'safety-launch',
          'package_name': 'org.skivu.devicefixture',
        }),
        'safety-launch',
      );
      await Future<void>.delayed(const Duration(milliseconds: 800));
      final observation = await call('observe', {
        'mode': 'tree',
        'output': 'decision',
        'compact': true,
        'stable_wait_ms': 300,
      });
      final nodes = ((observation['tree'] as Map)['elements'] as List)
          .cast<Map>();
      final password = nodes.firstWhere((n) => n['password'] == true);
      final denied = await call('input_text', {
        'request_id': 'safety-password',
        'element_id': password['element_id'],
        'text': 'fixture-only',
        'mode': 'replace',
        'observation_id': observation['observation_id'],
        'service_instance_id': observation['service_instance_id'],
      });
      final button = nodes.firstWhere((n) => n['text'] == '发送测试消息');
      final input = {
        'request_id': 'safety-send',
        'element_id': button['element_id'],
        'observation_id': observation['observation_id'],
        'service_instance_id': observation['service_instance_id'],
      };
      final pending = await call('tap', input);
      safetyConfirmation = Completer<void>();
      log('safety-awaiting-local-confirmation', {
        'password': denied['error'],
        'sensitive': pending['error'],
      });
      await native.invokeMethod('attention', {'connectionId': connection});
      await safetyConfirmation!.future.timeout(const Duration(seconds: 90));
      final sent = await settled(await call('tap', input), 'safety-send');
      final after = await call('observe', {
        'mode': 'tree',
        'output': 'decision',
        'compact': true,
        'stable_wait_ms': 300,
      });
      final output = {
        'passwordCode': (denied['error'] as Map?)?['code'],
        'beforeApprovalCode': (pending['error'] as Map?)?['code'],
        'approvedState': sent['state'],
        'approvedExecuted': sent['action_executed'],
        'singleSendObserved':
            ((after['tree'] as Map?)?['elements'] as List? ?? [])
                .whereType<Map>()
                .any((n) => n['text'] == '测试发送计数：1'),
      };
      log('safety-result', output);
      await File(
        '/data/user/0/com.skyjjgw.independent.ski.deviceqa/files/device-safety-result.json',
      ).writeAsString(jsonEncode(output));
      await request('end', {'taskCapability': safetyCapability});
    } catch (e) {
      log('safety-error', e.toString());
    } finally {
      if (safetyCapability != null) {
        await request('end', {'taskCapability': safetyCapability});
      }
      await native.invokeMethod('finishService', {
        'taskId': 'device_safety_qa',
      });
      safetyCapability = null;
    }
  }

  Future<void> roleDraft() async {
    try {
      final record = openPlugins.records['org.skivu.device-control']!;
      if (!record.authorized)
        throw StateError('Enable the fixture package first');
      final role = demo.role, chat = demo.conversations[demo.conversation];
      await openPlugins.bindRole(
        record.manifest.id,
        role.id,
        enabled: true,
        chat: true,
      );
      final toolContext = openPlugins.companionContext(
        record,
        role.id,
        role.name,
        chat.id,
      );
      toolContext['callId'] = 'isolated-role-draft';
      final runtime = OpenPluginRuntime(
        registry: openPlugins,
        record: record,
        context: toolContext,
        effect: 'write',
        checkContext: () {
          if (!record.authorized ||
              openPlugins.bindingFor(record.manifest.id, role.id) == null)
            throw StateError('Role binding was revoked');
        },
        host: (method, params) async {
          throw StateError('Unexpected UI capability $method');
        },
      );
      final result = Map<String, dynamic>.from(
        await runtime.run('prepare_task', {
              'goal': '在便签准备明天的计划，保存后核对内容。',
              'appHint': '隔离测试便签',
            })
            as Map,
      );
      await File(
        '/data/user/0/com.skyjjgw.independent.ski.deviceqa/files/role-device-draft-result.json',
      ).writeAsString(jsonEncode(result));
      log('role-draft', result);
      if (mounted)
        await launchOpenPlugin(
          context,
          record,
          roleId: role.id,
          chatId: chat.id,
          action: 'new-task',
          payload: Map<String, dynamic>.from(
            (result['card'] as Map)['payload'] as Map,
          ),
        );
    } catch (e) {
      log('role-draft-error', e.toString());
    }
  }

  void log(String name, Object? data) {
    entries.add({'event': name, 'data': data});
    debugPrint('DEVICE_QA ${jsonEncode(entries.last)}');
    if (mounted) setState(() => status = '$name\n${jsonEncode(data)}');
  }

  Future<Map<String, dynamic>> request(
    String method,
    Map<String, dynamic> args,
  ) async {
    final raw = await native.invokeMethod<String>('request', {
      'connectionId': connection,
      'json': jsonEncode({'method': method, 'params': args}),
    });
    final result = Map<String, dynamic>.from(jsonDecode(raw!));
    if (result['error'] != null) log('device-error', result['error']);
    return result;
  }

  Future<void> connect() async {
    try {
      final list = await native.invokeListMethod<dynamic>('discover');
      log('discovery', list);
      final item = (list!.first as Map);
      final value = await native.invokeMapMethod<String, dynamic>('connect', {
        'component': item['component'],
      });
      connection = value!['connectionId'];
      log('pair', await request('pair', {}));
    } catch (e) {
      log('error', e.toString());
    }
  }

  Future<void> run() async {
    try {
      const id = 'device_native_qa';
      log('hello', await request('hello', {}));
      await native.invokeMethod('startService', {'taskId': id});
      runner = DeviceTaskRunner(
        id: id,
        request: request,
        apps: {'org.skivu.devicefixture'},
        maxActions: 8,
        maxRounds: 6,
        deadline: DateTime.now().add(const Duration(minutes: 2)),
        check: () {},
        waitForConfirmation: () async {
          throw StateError('Fixture should not need a sensitive action');
        },
        update: (state, summary) async {
          log('state', {'state': state, 'summary': summary});
        },
        plan: (observation, receipts) async {
          final nodes = ((observation['tree'] as Map)['elements'] as List)
              .cast<Map>();
          log('observed', {
            'package': observation['package_name'],
            'elements': nodes,
          });
          final saved = nodes
              .where(
                (n) => (n['text'] ?? '').toString().contains(
                  '已保存：你好，Skivu 真实设备测试',
                ),
              )
              .firstOrNull;
          Map<String, dynamic> result;
          if (saved != null) {
            result = {
              'done': true,
              'summary': '真实文字输入与按钮点击已核对。',
              'action': '',
              'arguments': {},
              'evidenceIds': [saved['element_id']],
            };
          } else {
            final editor = nodes
                .where(
                  (n) =>
                      n['editable'] == true ||
                      (n['class'] ?? '').toString().contains('EditText'),
                )
                .first;
            if (editor['text'] != '你好，Skivu 真实设备测试') {
              result = {
                'done': false,
                'summary': '填写隔离测试便签',
                'action': 'input_text',
                'arguments': {
                  'element_id': editor['element_id'],
                  'text': '你好，Skivu 真实设备测试',
                  'mode': 'replace',
                },
                'evidenceIds': [],
              };
            } else {
              final button = nodes.firstWhere((n) => n['text'] == '保存便签');
              result = {
                'done': false,
                'summary': '保存测试便签',
                'action': 'tap',
                'arguments': {'element_id': button['element_id']},
                'evidenceIds': [],
              };
            }
          }
          return jsonEncode(result);
        },
      );
      await runner!.run();
      log('finished', {
        'actions': runner!.count,
        'rounds': runner!.rounds,
        'receipts': runner!.receipts,
      });
      final output = File(
        '/data/user/0/com.skyjjgw.independent.ski.deviceqa/files/device-qa-result.json',
      );
      await output.parent.create(recursive: true);
      await output.writeAsString(jsonEncode(entries));
      await native.invokeMethod('finishService', {'taskId': id});
    } catch (e) {
      log('error', e.toString());
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Device isolated QA')),
    body: SingleChildScrollView(
      child: Column(
        children: [
          Text(status),
          FilledButton(
            onPressed: connect,
            child: const Text('1. Connect / Pair'),
          ),
          FilledButton(
            onPressed: () => native.invokeMethod('openCompanion', {
              'connectionId': connection,
            }),
            child: const Text('2. Open local approval'),
          ),
          FilledButton(
            onPressed: run,
            child: const Text('3. Run real fixture'),
          ),
          FilledButton(
            onPressed: probes,
            child: const Text('4. Policy probes'),
          ),
          FilledButton(
            onPressed: openPlugin,
            child: const Text('5. Open independent plugin'),
          ),
          FilledButton(
            onPressed: safety,
            child: const Text('6. Safety confirmation fixture'),
          ),
          FilledButton(
            onPressed: () => openPlugin(waitOnly: true),
            child: const Text('7. Plugin cancellation fixture'),
          ),
          FilledButton(
            onPressed: roleDraft,
            child: const Text('8. Role draft SDK fixture'),
          ),
          FilledButton(
            onPressed: () async {
              log('status', await request('hello', {}));
            },
            child: const Text('Check authorization'),
          ),
          FilledButton(
            onPressed: () async {
              await runner?.cancel();
              log('cancel', 'requested');
            },
            child: const Text('Stop'),
          ),
        ],
      ),
    ),
  );
}

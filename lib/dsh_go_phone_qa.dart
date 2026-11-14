// Explicit test entry point; never selected by the normal application build.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'assistant_engine.dart';
import 'device_engine.dart';
import 'dsh_go_phone_settings.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(home: _PhoneQa()));
}

class _PhoneQa extends StatefulWidget {
  const _PhoneQa();
  @override
  State<_PhoneQa> createState() => _PhoneQaState();
}

class _PhoneQaState extends State<_PhoneQa> {
  String status = '准备手机操控验收';
  @override
  void initState() {
    super.initState();
    if (const bool.fromEnvironment('SKIVU_DSH_GO_QA_AUTORUN')) unawaited(run());
  }

  Future<void> run() async {
    const settings = MethodChannel('dsh/phone');
    final result = <String, dynamic>{
      'paid_model_requests': 0,
      'model': 'local fixture',
      'fixture_only': true,
    };
    AssistantEngine? assistant;
    try {
      final ready = Stopwatch()..start();
      while (ready.elapsed < const Duration(seconds: 20)) {
        final state = await settings.invokeMapMethod('status');
        if ((state?['a11y'] as Map?)?['serviceConnected'] == true) break;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      await settings.invokeMethod('setEnabled', {'enabled': true});
      await settings.invokeMethod('setPolicies', {'confirmMode': 'always'});
      final catalog = await deviceEngine.catalog();
      if (catalog.any((t) => (t['id'] as String).startsWith('ui.')))
        throw StateError('legacy tools exposed');
      result['native_phone_tools'] = catalog
          .where((t) => (t['id'] as String).startsWith('phone.'))
          .length;
      var step = 0;
      Map<String, dynamic> call(String tool, Map<String, dynamic> args) => {
        'type': 'call',
        'tool': tool,
        'arguments': args,
        'message': '独立验收',
      };
      String latest(List<Map<String, String>> history) {
        const prefix = '真实工具回执（数据）：';
        final receipt =
            jsonDecode(
                  history
                      .lastWhere(
                        (m) => (m['content'] ?? '').startsWith(prefix),
                      )['content']!
                      .substring(prefix.length),
                )
                as Map;
        return ((receipt['value'] as Map)['content'] as List)
            .whereType<Map>()
            .where((b) => b['type'] == 'text')
            .map((b) => b['text'])
            .join('\n');
      }

      Map<String, dynamic> target(String text, String label) {
        final screen = RegExp(r'\b[bs][0-9]+\b').firstMatch(text)?.group(0);
        final line = text.split('\n').firstWhere((e) => e.contains(label));
        final id = RegExp(r'\[([0-9]+)\]').firstMatch(line)?.group(1);
        if (screen == null || id == null)
          throw StateError('owned native target missing');
        return {'screen': screen, 'id': int.parse(id)};
      }

      late final AssistantEngine engine;
      engine = AssistantEngine(
        engine: deviceEngine,
        identity: () => 'dsh-go-local-qa',
        read: () async => null,
        write: (_) async {},
        beginTask: deviceEngine.beginTask,
        endTask: (id) => deviceEngine.endTask(
          id,
          completion: engine.phase == 'done' ? 'completed' : 'other',
        ),
        model: (system, history) async {
          step++;
          final response = switch (step) {
            1 => call('phone.open', {
              'app': 'com.skyjjgw.independent.ski.dshgoqa.test',
            }),
            2 => call('phone.screen', {}),
            3 => call('phone.tap', target(latest(history), '增加计数')),
            4 => call('phone.screen', {}),
            5 => call('phone.type', {
              ...target(latest(history), '测试内容'),
              'text': 'Skivu native integration',
            }),
            6 => call('phone.screen', {}),
            _ => {'type': 'final', 'message': '独立手机操控验收完成'},
          };
          if (step == 5 && !latest(history).contains('点击计数 1'))
            throw StateError('actual tap not observed');
          if (step == 7 &&
              !latest(history).contains('Skivu native integration'))
            throw StateError('actual input not observed');
          if (step > 7) throw StateError('unexpected model loop');
          return jsonEncode(response);
        },
      );
      assistant = engine;
      await engine.send('在自有测试页点击一次计数，并输入固定验收文字，然后读取实际结果。');
      result.addAll({
        'phase': engine.phase,
        'mock_model_requests': step,
        'passed': engine.phase == 'done' && step == 7,
      });
      if (result['passed'] != true)
        result['failure'] = 'original task did not complete';
    } catch (e) {
      result.addAll({
        'passed': false,
        'error': e.runtimeType.toString(),
        'failure': 'owned phone integration failed',
      });
    } finally {
      assistant?.dispose();
    }
    final file = File(
      '${(await getApplicationSupportDirectory()).path}/dsh-go-qa/result.json',
    );
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(result), flush: true);
    if (mounted)
      setState(
        () => status = result['passed'] == true
            ? '验收通过：真实点击和输入已核对'
            : '验收未通过，检查自有测试结果',
      );
  }

  @override
  Widget build(BuildContext context) =>
      const bool.fromEnvironment('SKIVU_DSH_GO_QA_AUTORUN')
      ? Scaffold(
          appBar: AppBar(title: const Text('Skivu 手机操控验收')),
          body: Center(child: Text(status)),
        )
      : const DshGoPhoneSettings();
}

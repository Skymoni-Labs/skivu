import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'assistant_engine.dart';
import 'assistant_plugin_tools.dart';
import 'chat_api.dart';
import 'device_engine.dart';
import 'embedded_engine_settings.dart';
import 'glass.dart';
import 'state.dart';

ChatSession? _session;
String _identity() => sha256
    .convert(
      utf8.encode(
        jsonEncode({
          'connection': demo.activeConnection?.toJson(),
          'account': demo.useAccount,
          'beta': demo.useBeta,
          'revision': demo.account.authorizationRevision,
          'user': demo.account.user?['id'],
        }),
      ),
    )
    .toString();

final AssistantEngine cloudAssistant = AssistantEngine(
  beginTask: deviceEngine.beginTask,
  endTask: deviceEngine.endTask,
  extensions: AssistantPluginTools(demo.plugins),
  identity: _identity,
  cancelModel: () => _session?.cancel(),
  model: (system, history) async {
    final expected = _identity();
    final session = await demo.startAssistantReply(system, history);
    if (!cloudAssistant.running || expected != _identity()) {
      session.cancel();
      throw StateError('规划已取消或连接已更换。');
    }
    _session = session;
    final output = StringBuffer();
    var limited = false;
    try {
      await for (final event in session.events) {
        output.write(event.text);
        limited = limited || event.limited;
      }
      if (session.cancelled) throw StateError('规划已取消。');
      if (limited) throw AssistantOutputLimit(session.effectiveMaxOutput);
      return output.toString();
    } finally {
      if (identical(_session, session)) _session = null;
    }
  },
);

bool _watching = false;

class CloudAssistantPane extends StatefulWidget {
  const CloudAssistantPane({super.key});
  @override
  State<CloudAssistantPane> createState() => _CloudAssistantPaneState();
}

class _CloudAssistantPaneState extends State<CloudAssistantPane> {
  final input = TextEditingController();
  final controls = GlobalKey();
  bool revealQueued = false;
  int messageCount = -1;

  void revealControls() {
    if (revealQueued) return;
    revealQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      revealQueued = false;
      final target = controls.currentContext;
      if (!mounted || target == null) return;
      // Keep this module's controls above the existing floating navigation.
      unawaited(
        Scrollable.ensureVisible(
          target,
          alignment: .68,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        ),
      );
    });
  }

  void assistantChanged() {
    if (messageCount == cloudAssistant.messages.length) return;
    messageCount = cloudAssistant.messages.length;
    if (messageCount > 0) revealControls();
  }

  @override
  void initState() {
    super.initState();
    cloudAssistant.addListener(assistantChanged);
    input.addListener(revealControls);
    if (!_watching) {
      _watching = true;
      demo.addListener(cloudAssistant.identityChanged);
      DeviceEngine.channel.setMethodCallHandler((call) async {
        if (call.method == 'taskStopped' &&
            (call.arguments as Map?)?['taskId'] == cloudAssistant.taskId) {
          await cloudAssistant.stop();
        }
      });
    }
    unawaited(cloudAssistant.restore().then((_) => assistantChanged()));
  }

  @override
  void dispose() {
    cloudAssistant.removeListener(assistantChanged);
    input.removeListener(revealControls);
    input.dispose();
    super.dispose();
  }

  void send() {
    if (input.text.trim().isEmpty) return;
    final text = input.text;
    input.clear();
    unawaited(cloudAssistant.send(text));
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: cloudAssistant,
    builder: (context, _) {
      final assistant = cloudAssistant;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '直接告诉小云你想做什么',
                  style: TextStyle(color: sceneInk, fontSize: 15),
                ),
              ),
              IconButton(
                tooltip: '手机能力与授权',
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const EmbeddedEngineSettings(),
                  ),
                ),
                icon: Icon(Icons.phonelink_setup, color: sceneInk),
              ),
            ],
          ),
          Text(
            '使用当前模型，独立保存对话。需要的手机权限可在右侧设置中开启。',
            style: TextStyle(color: sceneMuted, fontSize: 12),
          ),
          const SizedBox(height: 12),
          for (final message in assistant.messages)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: GlassSurface(
                radius: 20,
                opacity: message['role'] == 'user' ? .32 : .48,
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: SelectableText(
                    '${message['role'] == 'tool' ? '↳ ' : ''}${message['content']}',
                    style: TextStyle(
                      color: ink,
                      fontSize: message['role'] == 'tool' ? 12 : 14,
                      height: 1.6,
                    ),
                  ),
                ),
              ),
            ),
          if (assistant.running) ...[
            const LinearProgressIndicator(),
            Text(
              assistant.phase == 'thinking'
                  ? '小云正在规划…'
                  : assistant.phase == 'stopping'
                  ? '正在停止本次任务并核对进程…'
                  : '正在执行并核对回执…',
              style: TextStyle(color: sceneMuted),
            ),
          ],
          if (assistant.phase == 'permission') ...[
            Text('本次已暂停，完成手机能力授权后可继续。', style: TextStyle(color: sceneInk)),
            TextButton.icon(
              onPressed: assistant.resume,
              icon: const Icon(Icons.play_arrow),
              label: const Text('核对授权并继续'),
            ),
          ],
          if (assistant.phase == 'unknown')
            Text('上次操作的结果不确定，请先核对手机实际状态。', style: TextStyle(color: sceneInk)),
          const SizedBox(height: 12),
          TextField(
            controller: input,
            minLines: 1,
            maxLines: 5,
            enabled: !assistant.running && !assistant.canResume,
            key: const ValueKey('cloud-assistant-input'),
            decoration: const InputDecoration(
              hintText: '例如：帮我设置手机闹钟…',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.all(Radius.circular(20)),
              ),
            ),
          ),
          Row(
            key: controls,
            children: [
              Expanded(
                child: Text(
                  demo.activeConnection?.model ?? '请先配置模型',
                  style: TextStyle(fontSize: 11, color: sceneMuted),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (assistant.running || assistant.canResume)
                TextButton.icon(
                  onPressed: assistant.phase == 'stopping'
                      ? null
                      : assistant.stop,
                  icon: const Icon(Icons.stop),
                  label: const Text('停止'),
                )
              else
                FilledButton.icon(
                  onPressed: send,
                  icon: const Icon(Icons.arrow_upward),
                  label: const Text('发送'),
                ),
            ],
          ),
        ],
      );
    },
  );
}

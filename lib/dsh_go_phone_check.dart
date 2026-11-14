import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Presents the original native diagnostic report; unobserved stages are never
/// promoted to a pass. Closing cancels only the run accepted for this dialog.
class DshGoPhoneCheck extends StatefulWidget {
  const DshGoPhoneCheck({super.key});
  @override
  State<DshGoPhoneCheck> createState() => _DshGoPhoneCheckState();
}

class _DshGoPhoneCheckState extends State<DshGoPhoneCheck> {
  static const channel = MethodChannel('dsh/phone');
  static const labels = {
    'device': '设备',
    'channel': '授权连接',
    'display': '后台屏',
    'input_probe': '输入通道',
    'launch': '测试页启动',
    'tree': '控件读取',
    'tap': '点击',
    'scroll': '滚动',
    'back': '返回',
    'text_ascii': '英文输入',
    'text_zh': '中文输入',
    'capture': '截图',
    'continuity': '屏幕连续性',
    'main': '主屏影响',
    'ocr': '文字识别',
    'cleanup': '释放资源',
  };
  Map report = {};
  String? handle, error;
  Timer? timer;
  bool get active => const {'running', 'cleaning'}.contains(report['state']);
  @override
  void initState() {
    super.initState();
    unawaited(start());
  }

  Future<void> start() async {
    try {
      final value = await channel.invokeMapMethod('startPhoneSelfCheck', {
        'v': 1,
      });
      if (value?['accepted'] == true && value?['runHandle'] is String)
        handle = value!['runHandle'];
      if (!mounted) {
        await cancel();
        return;
      }
      setState(() {
        report = value ?? {};
        if (value?['accepted'] != true) error = '当前无法开始检查，请确认授权连接和任务状态。';
      });
      schedule();
    } catch (_) {
      if (mounted) setState(() => error = '无法读取手机操控检查结果。');
    }
  }

  void schedule() {
    if (mounted && active && handle != null)
      timer = Timer(const Duration(milliseconds: 500), () => unawaited(poll()));
  }

  Future<void> poll() async {
    try {
      final value = await channel.invokeMapMethod('phoneSelfCheckStatus');
      if (!mounted) return;
      if (value?['runHandle'] != handle) {
        setState(() => error = '这次检查已失效，请重新打开。');
        return;
      }
      setState(() => report = value ?? {});
      schedule();
    } catch (_) {
      if (mounted) setState(() => error = '无法继续读取检查结果。');
    }
  }

  Future<void> cancel() async {
    final owned = handle;
    if (owned == null) return;
    try {
      await channel.invokeMethod('cancelPhoneSelfCheck', {
        'v': 1,
        'runHandle': owned,
      });
    } catch (_) {
      /* Native ownership and cleanup fencing remain authoritative. */
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    if (active) unawaited(cancel());
    super.dispose();
  }

  String result(Map step) {
    if (step['observed'] != true)
      return step['state'] == 'not_run' ? '未运行' : '未核实';
    return switch (step['state']) {
      'pass' => '通过',
      'fail' => '未通过',
      _ => '未核实',
    };
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('手机操控环境检查'),
    content: SizedBox(
      width: 440,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('当前运行连接与后台屏探测；未运行项目不代表通过。具体应用操作仍需实际验证。'),
            if (active) const LinearProgressIndicator(),
            if (error != null) Text(error!),
            for (final step
                in (report['steps'] as List? ?? []).whereType<Map>())
              if (labels.containsKey(step['stage']))
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(labels[step['stage']]!),
                  trailing: Text(result(step)),
                ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(active ? '停止并关闭' : '关闭'),
      ),
    ],
  );
}

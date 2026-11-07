import 'dart:async';
import 'dart:convert';
import 'dart:ui' show FramePhase;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:ski/cloud_companion_portrait.dart';

/// Standalone, credential-free render fixture. Build with
/// --profile --dart-define=SKIVU_DEVICE_PREVIEW=true; never run a test runner
/// against the main application (the integration runner uninstalls its target).
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(home: _MotionProfile()));
}

class _MotionProfile extends StatefulWidget {
  const _MotionProfile();
  @override
  State<_MotionProfile> createState() => _MotionProfileState();
}

class _MotionProfileState extends State<_MotionProfile>
    with SingleTickerProviderStateMixin {
  bool smooth = false, running = false, recording = false;
  final frames = <FrameTiming>[];
  final elapsed = Stopwatch();
  Timer? timer;
  CloudActivity activity = CloudActivity.coding;
  bool control = false;
  late final AnimationController clock = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  )..repeat();
  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addTimingsCallback(timings);
  }

  void timings(List<FrameTiming> value) {
    if (recording) frames.addAll(value);
  }

  void start() {
    setState(() => running = true);
    frames.clear();
    timer = Timer(const Duration(seconds: 3), () {
      frames.clear();
      recording = true;
      elapsed
        ..reset()
        ..start();
      timer = Timer(const Duration(seconds: 12), finish);
    });
  }

  void finish() {
    if (control) debugPrint('CLOUD_MOTION_LIGHT_CONTROL');
    recording = false;
    elapsed.stop();
    final refresh = View.of(context).display.refreshRate;
    double percentile(List<double> values, double p) {
      values.sort();
      return values.isEmpty ? 0 : values[((values.length - 1) * p).round()];
    }

    final raster = frames
        .map((f) => f.rasterDuration.inMicroseconds / 1000)
        .toList();
    final build = frames
        .map((f) => f.buildDuration.inMicroseconds / 1000)
        .toList();
    final vsync =
        frames
            .map((f) => f.timestampInMicroseconds(FramePhase.vsyncStart))
            .toList()
          ..sort();
    final gaps = [
      for (var i = 1; i < vsync.length; i++) (vsync[i] - vsync[i - 1]) / 1000,
    ];
    debugPrint(
      'CLOUD_MOTION_PROFILE ${jsonEncode({'smooth': smooth, 'state': activity.name, 'refreshRate': refresh, 'frames': frames.length, 'sampleSeconds': elapsed.elapsedMicroseconds / 1000000, 'rasterP50Ms': percentile(raster, .5), 'rasterP95Ms': percentile(raster, .95), 'buildP95Ms': percentile(build, .95), 'frameGapP50Ms': percentile(gaps, .5), 'frameGapP95Ms': percentile(gaps, .95), 'rasterOverBudget': raster.where((t) => t > 1000 / refresh).length, 'scope': 'isolated Android profile render fixture, no glass or model calls'})}',
    );
    setState(() => running = false);
  }

  @override
  void dispose() {
    timer?.cancel();
    clock.dispose();
    SchedulerBinding.instance.removeTimingsCallback(timings);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xffedf8ff), Color(0xffdceaff)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('小云 · 动作渲染采样'),
              if (control)
                SizedBox(
                  width: 220,
                  height: 242,
                  child: AnimatedBuilder(
                    animation: clock,
                    builder: (_, _) => Transform.translate(
                      offset: Offset(clock.value * 100, 0),
                      child: const Center(
                        child: SizedBox(
                          width: 24,
                          height: 24,
                          child: ColoredBox(color: Colors.blue),
                        ),
                      ),
                    ),
                  ),
                )
              else
                CloudCompanionPortrait(
                  key: ValueKey('$smooth-${activity.name}'),
                  size: 220,
                  activity: activity,
                  smoothMotion: smooth,
                  previewEnabled: false,
                ),
              SwitchListTile(
                title: const Text('连续过渡'),
                value: smooth,
                onChanged: running
                    ? null
                    : (value) => setState(() => smooth = value),
              ),
              SwitchListTile(
                title: const Text('纯色对照'),
                value: control,
                onChanged: running
                    ? null
                    : (value) => setState(() => control = value),
              ),
              Wrap(
                children: [
                  for (final state in [
                    CloudActivity.idle,
                    CloudActivity.coding,
                    CloudActivity.phone,
                  ])
                    TextButton(
                      onPressed: running
                          ? null
                          : () => setState(() => activity = state),
                      child: Text(state.name),
                    ),
                ],
              ),
              FilledButton(
                onPressed: running ? null : start,
                child: Text(running ? '采样中' : '开始采样'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

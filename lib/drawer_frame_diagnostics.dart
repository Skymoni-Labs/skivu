import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:ui' show FramePhase;
import 'package:flutter/scheduler.dart';
import 'package:flutter/foundation.dart';

/// Opt-in local frame evidence; absent from ordinary release builds. No content,
/// device identifiers or settings are recorded, and nothing is transmitted.
class DrawerFrameDiagnostics {
  static const enabled =
      bool.fromEnvironment('SKIVU_DRAWER_DIAGNOSTICS') ||
      bool.fromEnvironment('SKIVU_FRAME_DIAGNOSTICS');
  DrawerFrameDiagnostics({this.scope = 'drawer'}) {
    if (enabled) SchedulerBinding.instance.addTimingsCallback(_frames);
  }
  final String scope;
  final _intervals = <(int, int?)>[];
  void motion(bool moving, double offset) {
    if (!enabled) return;
    final now = developer.Timeline.now;
    if (moving) {
      _intervals.add((now, null));
      if (_intervals.length > 64) _intervals.removeAt(0);
    } else if (_intervals.isNotEmpty) {
      _intervals[_intervals.length - 1] = (_intervals.last.$1, now);
    }
    debugPrint(
      'SkivuPerf ${jsonEncode({'event': 'motion', 'scope': scope, 'us': now, 'moving': moving, 'offset': offset})}',
    );
  }

  void _frames(List<FrameTiming> timings) {
    final samples = [
      for (final f in timings)
        if (_intervals.any((range) {
          final t = f.timestampInMicroseconds(FramePhase.buildStart);
          return t >= range.$1 && (range.$2 == null || t <= range.$2!);
        }))
          {
            'start': f.timestampInMicroseconds(FramePhase.buildStart),
            'ui': f.buildDuration.inMicroseconds,
            'raster': f.rasterDuration.inMicroseconds,
            'total': f.totalSpan.inMicroseconds,
          },
    ];
    // Android truncates long log entries. Small batches retain every sample.
    for (var i = 0; i < samples.length; i += 8) {
      debugPrint(
        'SkivuPerf ${jsonEncode({'event': 'frames', 'scope': scope, 'frames': samples.sublist(i, (i + 8).clamp(0, samples.length))})}',
      );
    }
  }

  void dispose() {
    if (enabled) SchedulerBinding.instance.removeTimingsCallback(_frames);
  }
}

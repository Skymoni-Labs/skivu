import 'dart:ui' as ui;
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'cloud_companion_motion.dart';
import 'cloud_companion_painter.dart';
import 'cloud_companion_reference.dart';
import 'cloud_pet_pack.dart';

export 'cloud_companion_motion.dart';

const cloudCompanionAsset = 'assets/branding/skivu-cloud-motion-reference.png';

/// Reference-matched illustrated artwork plus one animated body/arm/prop rig.
class CloudCompanionPortrait extends StatefulWidget {
  const CloudCompanionPortrait({
    super.key,
    this.size = 104,
    this.reduceMotion = false,
    this.activity = CloudActivity.idle,
    this.active = true,
  });
  final double size;
  final bool reduceMotion, active;
  final CloudActivity activity;
  @override
  State<CloudCompanionPortrait> createState() => _CloudCompanionPortraitState();
}

class _CloudCompanionPortraitState extends State<CloudCompanionPortrait>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late final clock = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 8),
  );
  late final transition = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 240),
    value: 1,
  );
  late final AnimationController petExit =
      AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 300),
      )..addStatusListener((status) {
        if (status == AnimationStatus.completed &&
            exitTarget != null &&
            mounted) {
          final target = exitTarget!;
          final overflow =
              Duration(
                microseconds: ((motionSeconds - exitBeganAtSeconds) * 1000000)
                    .round(),
              ) -
              petExit.duration!;
          setState(() {
            applyActivity(target);
            if (overflow > Duration.zero) {
              transition.value =
                  (overflow.inMicroseconds /
                          transition.duration!.inMicroseconds)
                      .clamp(0, 1);
              if (transition.value < 1 && enabled) transition.forward();
            }
          });
        }
      });
  ui.Image? image;
  ui.Image? petAtlas;
  CloudReferenceRig? rig;
  CloudPetPack? petPack;
  late CloudActivity displayedActivity;
  CloudActivity? exitTarget;
  double motionSeconds = 0;
  double exitBeganAtSeconds = 0;
  Duration lastClockElapsed = Duration.zero;
  bool resettingClock = false;
  int workspace = 0;
  bool foreground = true, greeting = false;
  bool onScreen = true, visibilityScheduled = false;
  ScrollableState? scrollable;
  late CloudPose from, to;
  List<CloudVisualLayer> outgoing = [];
  bool get reduced =>
      widget.reduceMotion || MediaQuery.disableAnimationsOf(context);
  bool get enabled =>
      widget.active &&
      foreground &&
      onScreen &&
      TickerMode.of(context) &&
      !reduced;
  CloudPose get pose => CloudPose.lerp(
    from,
    to,
    Curves.easeInOutCubic.transform(transition.value),
  );

  List<CloudVisualLayer> layers(CloudActivity activity) {
    final t = reduced ? 1.0 : Curves.easeInOut.transform(transition.value);
    return [
      for (final layer in outgoing)
        if (layer.opacity * (1 - t) > .001)
          layer.withOpacity(layer.opacity * (1 - t)),
      if (t > .001)
        CloudVisualLayer(
          activity: activity,
          pose: pose,
          seconds: enabled
              ? exitTarget != null
                    ? petExit.value * petExit.duration!.inMicroseconds / 1000000
                    : motionSeconds
              : 0,
          opacity: t,
          greeting:
              greeting &&
              (clock.lastElapsedDuration ?? Duration.zero) <
                  const Duration(seconds: 2),
          petSegment: exitTarget != null ? CloudPetSegment.end : null,
        ),
    ];
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    displayedActivity = widget.activity;
    clock.addListener(advanceMotion);
    workspace = switch (widget.activity) {
      CloudActivity.coding => 1,
      CloudActivity.phone => 2,
      _ => 0,
    };
    from = to = CloudPose.forActivity(widget.activity, workspace);
    load();
  }

  Future<void> load() async {
    try {
      final data = await rootBundle.load(cloudCompanionAsset);
      final reference = CloudReferenceRig(
        jsonDecode(
              await rootBundle.loadString(
                'assets/branding/skivu-cloud-reference-masks.json',
                cache: false,
              ),
            )
            as Map<String, dynamic>,
      );
      final codec = await ui.instantiateImageCodec(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        targetWidth: 1536,
      );
      try {
        final frame = await codec.getNextFrame();
        try {
          await reference.prepare(frame.image);
        } catch (_) {
          reference.dispose();
          frame.image.dispose();
          rethrow;
        }
        final pet = await loadPetPack();
        if (!mounted) {
          frame.image.dispose();
          reference.dispose();
          pet?.$2.dispose();
          return;
        }
        setState(() {
          image = frame.image;
          rig = reference;
          petPack = pet?.$1;
          petAtlas = pet?.$2;
        });
      } finally {
        codec.dispose();
      }
    } catch (error, stack) {
      assert(() {
        debugPrint('Cloud animation asset failed: $error');
        debugPrintStack(stackTrace: stack);
        return true;
      }());
    }
  }

  Future<(CloudPetPack, ui.Image)?> loadPetPack() async {
    ui.Image? atlas;
    try {
      final pack = CloudPetPack.fromJson(
        jsonDecode(
              await rootBundle.loadString(
                'assets/branding/cloud_pet/coding-v1.json',
                cache: false,
              ),
            )
            as Map<String, dynamic>,
      );
      final data = await rootBundle.load(pack.atlas);
      final codec = await ui.instantiateImageCodec(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
      try {
        atlas = (await codec.getNextFrame()).image;
        pack.validateAtlas(
          Size(atlas.width.toDouble(), atlas.height.toDouble()),
        );
        return (pack, atlas);
      } finally {
        codec.dispose();
      }
    } catch (error) {
      atlas?.dispose();
      assert(() {
        debugPrint('Cloud pet pack unavailable: $error');
        return true;
      }());
      return null; // Keep the existing illustration usable if the pack fails.
    }
  }

  void advanceMotion() {
    if (resettingClock) return;
    final elapsed = clock.lastElapsedDuration ?? Duration.zero;
    final delta = elapsed - lastClockElapsed;
    if (!delta.isNegative) motionSeconds += delta.inMicroseconds / 1000000;
    lastClockElapsed = elapsed;
  }

  void syncClock({bool restart = false}) {
    if (restart) {
      resettingClock = true;
      motionSeconds = 0;
      lastClockElapsed = Duration.zero;
      clock.value = 0;
      resettingClock = false;
    }
    if (!enabled) {
      clock.stop();
      transition.stop();
      petExit.stop();
      if (reduced) {
        transition.value = 1;
        if (exitTarget != null) applyActivity(exitTarget!);
      }
      return;
    }
    if (transition.value < 1 && !transition.isAnimating) transition.forward();
    if (exitTarget != null && !petExit.isAnimating) petExit.forward();
    if (displayedActivity.continuous) {
      if (restart || !clock.isAnimating) {
        lastClockElapsed = Duration.zero;
        clock.repeat();
      }
    } else if (restart || clock.value < 1) {
      clock.stop();
      lastClockElapsed = Duration.zero;
      clock.forward();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final parent = Scrollable.maybeOf(context);
    if (!identical(parent, scrollable)) {
      scrollable?.position.removeListener(scheduleVisibility);
      scrollable = parent;
      scrollable?.position.addListener(scheduleVisibility);
    }
    scheduleVisibility();
    syncClock();
  }

  void scheduleVisibility() {
    if (visibilityScheduled) return;
    visibilityScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      visibilityScheduled = false;
      if (!mounted) return;
      final object = context.findRenderObject();
      final viewport = scrollable?.context.findRenderObject();
      if (object is! RenderBox || !object.hasSize) return;
      final rect = object.localToGlobal(Offset.zero) & object.size;
      final screen = Offset.zero & MediaQuery.sizeOf(context);
      final visible =
          rect.overlaps(screen) &&
          (viewport is! RenderBox ||
              !viewport.hasSize ||
              rect.overlaps(
                viewport.localToGlobal(Offset.zero) & viewport.size,
              ));
      if (visible != onScreen) {
        setState(() => onScreen = visible);
        syncClock();
      }
    });
  }

  @override
  void didUpdateWidget(covariant CloudCompanionPortrait oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.activity != oldWidget.activity) {
      final target = widget.activity;
      final urgent = {
        CloudActivity.permission,
        CloudActivity.stopping,
        CloudActivity.paused,
        CloudActivity.failed,
      }.contains(target);
      if (petPack != null &&
          displayedActivity == CloudActivity.coding &&
          target != CloudActivity.coding &&
          !urgent &&
          oldWidget.active &&
          !oldWidget.reduceMotion &&
          enabled) {
        if (exitTarget == null) {
          exitBeganAtSeconds = motionSeconds;
          petExit.duration = Duration(milliseconds: petPack!.end.durationMs);
          petExit.value = 0;
        }
        exitTarget = target;
        syncClock();
      } else {
        applyActivity(target);
      }
    } else {
      syncClock();
    }
  }

  void applyActivity(CloudActivity target) {
    outgoing = layers(displayedActivity);
    petExit.stop();
    exitTarget = null;
    if (outgoing.length > 4) {
      outgoing.sort((a, b) => b.opacity.compareTo(a.opacity));
      outgoing = outgoing.take(4).toList();
      final sum = outgoing.fold(0.0, (v, e) => v + e.opacity);
      outgoing = outgoing.map((e) => e.withOpacity(e.opacity / sum)).toList();
    }
    from = pose;
    displayedActivity = target;
    if (target == CloudActivity.idle) workspace = 0;
    if (target == CloudActivity.coding) workspace = 1;
    if (target == CloudActivity.phone) workspace = 2;
    to = CloudPose.forActivity(target, workspace);
    greeting = false;
    transition.duration = Duration(
      milliseconds:
          {
            CloudActivity.permission,
            CloudActivity.stopping,
            CloudActivity.paused,
            CloudActivity.failed,
          }.contains(target)
          ? 120
          : 240,
    );
    transition.value = 0;
    syncClock(restart: true);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (mounted) {
      syncClock();
      setState(() {});
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    scrollable?.position.removeListener(scheduleVisibility);
    clock.dispose();
    transition.dispose();
    petExit.dispose();
    image?.dispose();
    petAtlas?.dispose();
    rig?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: '小云虚拟人物，${widget.activity.label}',
    hint: reduced || widget.activity != CloudActivity.idle ? null : '点击让小云挥手',
    button: !reduced && widget.activity == CloudActivity.idle,
    child: GestureDetector(
      key: const ValueKey('cloud-companion-portrait'),
      onTap: reduced || widget.activity != CloudActivity.idle
          ? null
          : () {
              greeting = true;
              syncClock(restart: true);
            },
      child: RepaintBoundary(
        child: SizedBox(
          width: widget.size,
          height: widget.size * 1.1,
          child: AnimatedBuilder(
            animation: Listenable.merge([clock, transition, petExit]),
            builder: (context, _) => image == null || rig == null
                ? Icon(
                    Icons.cloud_outlined,
                    size: widget.size * .65,
                    color: Theme.of(context).colorScheme.primary,
                  )
                : CustomPaint(
                    painter: CloudCompanionPainter(
                      image: image!,
                      rig: rig!,
                      pose: pose,
                      activity: displayedActivity,
                      seconds: enabled ? motionSeconds : 0,
                      entry: enabled ? transition.value : 1,
                      motion: enabled,
                      greeting: greeting,
                      layers: layers(displayedActivity),
                      petPack: petPack,
                      petAtlas: petAtlas,
                    ),
                  ),
          ),
        ),
      ),
    ),
  );
}

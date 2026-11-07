import 'dart:ui' as ui;
import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'cloud_companion_motion.dart';
import 'cloud_companion_painter.dart';
import 'cloud_companion_reference.dart';
import 'cloud_pet_pack.dart';
import 'cloud_pet_catalog.dart';

export 'cloud_companion_motion.dart';

const cloudCompanionAsset = 'assets/branding/skivu-cloud-motion-reference.png';
Future<ui.FragmentProgram?>? _motionProgram;
Future<ui.FragmentProgram?>
_loadMotionProgram() => _motionProgram ??= (() async {
  try {
    return await ui.FragmentProgram.fromAsset('shaders/cloud_motion.frag');
  } catch (_) {
    return null; // The approved original frames remain usable on unsupported renderers.
  }
})();

/// Reference-matched illustrated artwork plus one animated body/arm/prop rig.
class CloudCompanionPortrait extends StatefulWidget {
  const CloudCompanionPortrait({
    super.key,
    this.size = 104,
    this.reduceMotion = false,
    this.activity = CloudActivity.idle,
    this.active = true,
    this.previewEnabled = true,
    this.smoothMotion = true,
  });
  final double size;
  final bool reduceMotion, active, previewEnabled;
  final bool smoothMotion;
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
  ui.FragmentShader? motionShader;
  CloudReferenceRig? rig;
  CloudPetPack? petPack;
  CloudPetCatalog? petCatalog;
  Map<String, ui.Image> petAtlases = {};
  final pendingAtlases = <String, Future<void>>{};
  late CloudActivity displayedActivity;
  CloudActivity? exitTarget;
  double motionSeconds = 0;
  double exitBeganAtSeconds = 0;
  Duration lastClockElapsed = Duration.zero;
  bool resettingClock = false;
  int workspace = 0;
  bool foreground = true, greeting = false;
  bool onScreen = true, visibilityScheduled = false;
  bool previewOpen = false;
  ScrollableState? scrollable;
  Animation<double>? routeAnimation;
  late CloudPose from, to;
  List<CloudVisualLayer> outgoing = [];
  List<CloudVisualLayer>? presentedLayers;
  bool get reduced =>
      widget.reduceMotion || MediaQuery.disableAnimationsOf(context);
  bool get enabled =>
      widget.active &&
      !previewOpen &&
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
          smoothFrame:
              widget.smoothMotion &&
              motionShader != null &&
              petAtlases.containsKey(petCatalog?.packs[activity]?.flow?.atlas),
          petAtlasAsset: petCatalog == null
              ? null
              : petAtlases.containsKey(petCatalog!.packs[activity]!.atlas)
              ? petCatalog!.packs[activity]!.atlas
              : petCatalog!.fallbacks[activity]!.atlas,
        ),
    ];
  }

  void wave() {
    if (!enabled || displayedActivity != CloudActivity.idle) return;
    greeting = true;
    syncClock(restart: true);
  }

  Future<void> openPreview() async {
    if (!widget.previewEnabled || previewOpen) return;
    setState(() => previewOpen = true);
    syncClock();
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: true,
        builder: (_) => CloudCompanionPreview(reduceMotion: reduced),
      );
    } finally {
      if (mounted) {
        setState(() => previewOpen = false);
        syncClock();
      }
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    displayedActivity = widget.activity;
    clock.addListener(advanceMotion);
    transition.addStatusListener((status) {
      if (status == AnimationStatus.completed &&
          mounted &&
          petCatalog != null) {
        setState(() {
          outgoing = [];
          trimPetAtlases();
        });
      }
    });
    workspace = switch (widget.activity) {
      CloudActivity.coding => 1,
      CloudActivity.phone => 2,
      _ => 0,
    };
    from = to = CloudPose.forActivity(widget.activity, workspace);
    load();
    if (widget.smoothMotion) unawaited(loadShader());
  }

  Future<void> loadShader() async {
    final program = await _loadMotionProgram();
    if (mounted && program != null)
      setState(() => motionShader = program.fragmentShader());
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
        final workflow = await loadPetCatalog();
        final pet = workflow == null ? await loadPetPack() : null;
        if (!mounted) {
          frame.image.dispose();
          reference.dispose();
          pet?.$2.dispose();
          for (final atlas in workflow?.$2.values ?? <ui.Image>[]) {
            atlas.dispose();
          }
          return;
        }
        setState(() {
          image = frame.image;
          rig = reference;
          petCatalog = workflow?.$1;
          petAtlases = workflow?.$2 ?? {};
          petPack = petCatalog?.packs[CloudActivity.coding] ?? pet?.$1;
          petAtlas = petAtlases[petPack?.atlas] ?? pet?.$2;
        });
        ensurePetScene(displayedActivity);
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

  Future<ui.Image> decodePetAtlas(CloudPetPack pack) async {
    final data = await rootBundle.load(pack.atlas);
    final codec = await ui.instantiateImageCodec(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
    try {
      final image = (await codec.getNextFrame()).image;
      try {
        pack.validateAtlas(
          Size(image.width.toDouble(), image.height.toDouble()),
        );
        return image;
      } catch (_) {
        image.dispose();
        rethrow;
      }
    } finally {
      codec.dispose();
    }
  }

  Future<(CloudPetCatalog, Map<String, ui.Image>)?> loadPetCatalog() async {
    final atlases = <String, ui.Image>{};
    try {
      final catalog = CloudPetCatalog.fromJson(
        jsonDecode(
              await rootBundle.loadString(
                'assets/branding/cloud_pet/workflow-v1.json',
                cache: false,
              ),
            )
            as Map<String, dynamic>,
      );
      final fallback = catalog.fallbacks.values.first;
      atlases[fallback.atlas] = await decodePetAtlas(fallback);
      final current = catalog.packs[widget.activity]!;
      atlases[current.atlas] = await decodePetAtlas(current);
      return (catalog, atlases);
    } catch (error) {
      for (final image in atlases.values) {
        image.dispose();
      }
      assert(() {
        debugPrint('Cloud workflow unavailable: $error');
        return true;
      }());
      return null;
    }
  }

  void ensurePetScene(CloudActivity activity) {
    final pack = petCatalog?.packs[activity];
    final flow = widget.smoothMotion && !reduced ? pack?.flow : null;
    if (pack == null ||
        (petAtlases.containsKey(pack.atlas) &&
            (flow == null || petAtlases.containsKey(flow.atlas))) ||
        pendingAtlases.containsKey(pack.atlas))
      return;
    pendingAtlases[pack.atlas] = (() async {
      ui.Image? ownedArt, ownedField;
      try {
        final existing = petAtlases[pack.atlas];
        final image = existing ?? (ownedArt = await decodePetAtlas(pack));
        ui.Image? field;
        if (flow != null && !petAtlases.containsKey(flow.atlas)) {
          final data = await rootBundle.load(flow.atlas);
          final codec = await ui.instantiateImageCodec(
            data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          );
          try {
            field = ownedField = (await codec.getNextFrame()).image;
            if (field.width != flow.size.width ||
                field.height != flow.size.height) {
              throw const FormatException(
                'Cloud motion field dimensions do not match',
              );
            }
          } finally {
            codec.dispose();
          }
        }
        if (!mounted) {
          ownedArt?.dispose();
          ownedField?.dispose();
          return;
        }
        setState(() {
          petAtlases = {
            ...petAtlases,
            pack.atlas: image,
            if (field != null) flow!.atlas: field,
          };
          trimPetAtlases();
        });
        ownedArt = null;
        ownedField = null;
      } catch (error) {
        ownedArt?.dispose();
        ownedField?.dispose();
        assert(() {
          debugPrint('Cloud scene unavailable: $error');
          return true;
        }());
      } finally {
        pendingAtlases.remove(pack.atlas);
      }
    })();
    unawaited(pendingAtlases[pack.atlas]!);
  }

  void trimPetAtlases() {
    final catalog = petCatalog;
    if (catalog == null) return;
    final required = {
      catalog.fallbacks.values.first.atlas,
      catalog.packs[displayedActivity]!.atlas,
      catalog.packs[widget.activity]!.atlas,
      if (exitTarget != null) catalog.packs[exitTarget]!.atlas,
      for (final layer in layers(displayedActivity))
        catalog.packs[layer.activity]!.atlas,
      for (final layer in outgoing)
        if (layer.petAtlasAsset != null) layer.petAtlasAsset!,
    };
    final next = {...petAtlases};
    final active = {
      displayedActivity,
      widget.activity,
      if (exitTarget != null) exitTarget!,
      for (final layer in outgoing) layer.activity,
    };
    for (final state in active) {
      final flow = catalog.packs[state]?.flow;
      if (flow != null) required.add(flow.atlas);
    }
    final flowPaths = {
      for (final pack in catalog.packs.values)
        if (pack.flow != null) pack.flow!.atlas,
    };
    for (final path in flowPaths) {
      if (!required.contains(path)) {
        final removed = next.remove(path);
        if (removed != null)
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => removed.dispose(),
          );
      }
    }
    for (final path in petAtlases.keys) {
      if (next.keys.where((p) => !flowPaths.contains(p)).length <= 4) break;
      if (required.contains(path)) continue;
      final removed = next.remove(path);
      if (removed == null) continue;
      WidgetsBinding.instance.addPostFrameCallback((_) => removed.dispose());
    }
    petAtlases = Map.unmodifiable(next);
    petAtlas = petAtlases[petPack?.atlas];
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
    final animation = ModalRoute.of(context)?.animation;
    if (!identical(animation, routeAnimation)) {
      routeAnimation?.removeListener(scheduleVisibility);
      routeAnimation = animation;
      routeAnimation?.addListener(scheduleVisibility);
    }
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
      ensurePetScene(target);
      final urgent = {
        CloudActivity.permission,
        CloudActivity.stopping,
        CloudActivity.paused,
        CloudActivity.failed,
      }.contains(target);
      final outgoingPack = petCatalog?.packs[displayedActivity] ?? petPack;
      if (outgoingPack != null &&
          {
            CloudActivity.coding,
            CloudActivity.phone,
            CloudActivity.thinking,
            CloudActivity.checking,
          }.contains(displayedActivity) &&
          target != displayedActivity &&
          !urgent &&
          oldWidget.active &&
          !oldWidget.reduceMotion &&
          enabled) {
        if (exitTarget == null) {
          exitBeganAtSeconds = motionSeconds;
          petExit.duration = Duration(
            milliseconds: outgoingPack.end.durationMs,
          );
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
    // Freeze the texture choice actually presented, including a coherent
    // loading frame. A late decode must not replace an outgoing snapshot.
    outgoing = presentedLayers ?? layers(displayedActivity);
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
    routeAnimation?.removeListener(scheduleVisibility);
    clock.dispose();
    transition.dispose();
    petExit.dispose();
    motionShader?.dispose();
    image?.dispose();
    if (petCatalog == null) {
      petAtlas?.dispose();
    } else {
      for (final atlas in petAtlases.values) {
        atlas.dispose();
      }
    }
    rig?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: '小云虚拟人物，${widget.activity.label}',
    hint: widget.previewEnabled
        ? '点击挥手，长按查看动作预览'
        : reduced || widget.activity != CloudActivity.idle
        ? null
        : '点击让小云挥手',
    button:
        widget.previewEnabled ||
        (!reduced && widget.activity == CloudActivity.idle),
    child: GestureDetector(
      key: const ValueKey('cloud-companion-portrait'),
      onTap: reduced || widget.activity != CloudActivity.idle ? null : wave,
      onLongPress: widget.previewEnabled ? openPreview : null,
      child: RepaintBoundary(
        child: SizedBox(
          width: widget.size,
          height: widget.size * 1.1,
          child: AnimatedBuilder(
            animation: Listenable.merge([clock, transition, petExit]),
            builder: (context, _) {
              final drawnLayers = layers(displayedActivity);
              presentedLayers = drawnLayers;
              return image == null || rig == null
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
                        layers: drawnLayers,
                        petPack: petPack,
                        petAtlas: petAtlas,
                        petCatalog: petCatalog,
                        petAtlases: petAtlases,
                        motionShader: widget.smoothMotion ? motionShader : null,
                      ),
                    );
            },
          ),
        ),
      ),
    ),
  );
}

/// A local character gallery. Its state never reaches the assistant or tools.
class CloudCompanionPreview extends StatefulWidget {
  const CloudCompanionPreview({super.key, this.reduceMotion = false});
  final bool reduceMotion;
  @override
  State<CloudCompanionPreview> createState() => _CloudCompanionPreviewState();
}

class _CloudCompanionPreviewState extends State<CloudCompanionPreview>
    with WidgetsBindingObserver {
  static const phases = [
    (0, CloudActivity.idle),
    (3000, CloudActivity.thinking),
    (6000, CloudActivity.coding),
    (12000, CloudActivity.phone),
    (15500, CloudActivity.permission),
    (18500, CloudActivity.checking),
    (22000, CloudActivity.resultReady),
    (24500, CloudActivity.complete),
    (27500, CloudActivity.stopping),
    (30000, CloudActivity.paused),
    (32500, CloudActivity.failed),
    (35500, CloudActivity.idle),
  ];
  static const names = [
    '待机',
    '思考',
    '编程',
    '手机',
    '授权',
    '核对',
    '就绪',
    '完成',
    '停止',
    '暂停',
    '异常',
  ];
  final portrait = GlobalKey<_CloudCompanionPortraitState>();
  final elapsed = Stopwatch();
  Timer? timer;
  CloudActivity activity = CloudActivity.idle;
  bool playing = false;
  int phase = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  void stop() {
    timer?.cancel();
    timer = null;
    elapsed.stop();
    playing = false;
  }

  void select(CloudActivity value) {
    stop();
    elapsed.reset();
    phase = 0;
    setState(() => activity = value);
    portrait.currentState?.syncClock(restart: true);
  }

  void toggle() {
    if (playing) {
      setState(stop);
      return;
    }
    if (elapsed.elapsedMilliseconds == 0 ||
        elapsed.elapsedMilliseconds >= 38000) {
      elapsed.reset();
      phase = 0;
      setState(() => activity = CloudActivity.idle);
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => portrait.currentState?.wave(),
      );
    }
    setState(() => playing = true);
    elapsed.start();
    timer = Timer.periodic(const Duration(milliseconds: 80), (_) {
      final ms = elapsed.elapsedMilliseconds;
      // Stopwatch is real time on device; timer ticks do not drive raster frames.
      if (ms >= 38000) {
        setState(stop);
        return;
      }
      final next = phases.lastIndexWhere((p) => ms >= p.$1);
      if (next == phase) return;
      phase = next;
      setState(() => activity = phases[next].$2);
      if (activity == CloudActivity.idle) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => portrait.currentState?.wave(),
        );
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && playing) setState(stop);
  }

  @override
  void dispose() {
    stop();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduced =
        widget.reduceMotion || MediaQuery.disableAnimationsOf(context);
    final theme = Theme.of(context);
    return SizedBox(
      key: const ValueKey('cloud-motion-preview'),
      height: (MediaQuery.sizeOf(context).height * .86).clamp(0, 720),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('动作预览', style: theme.textTheme.titleLarge),
                ),
                IconButton(
                  tooltip: '关闭预览',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 8),
            CloudCompanionPortrait(
              key: portrait,
              size: 220,
              activity: activity,
              reduceMotion: reduced,
              previewEnabled: false,
            ),
            const SizedBox(height: 8),
            Text('演示：${activity.label}', style: theme.textTheme.titleMedium),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              onPressed: reduced ? null : toggle,
              icon: Icon(playing ? Icons.pause : Icons.play_arrow),
              label: Text(playing ? '暂停演示' : '播放全流程'),
            ),
            const SizedBox(height: 16),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final value in CloudActivity.values)
                  ChoiceChip(
                    label: Text(names[value.index]),
                    selected: activity == value,
                    onSelected: (_) => select(value),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              reduced ? '已减少动态效果，可切换查看静态姿态' : '待机时，轻点小云可以挥手',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

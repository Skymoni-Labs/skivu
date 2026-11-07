import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const cloudCompanionAsset = 'assets/branding/skivu-cloud-companion.png';

/// Reuses the website's original transparent character sheet and front pose.
/// The finite greeting never sends a message or starts a model request.
class CloudCompanionPortrait extends StatefulWidget {
  const CloudCompanionPortrait({
    super.key,
    this.size = 104,
    this.reduceMotion = false,
  });
  final double size;
  final bool reduceMotion;

  @override
  State<CloudCompanionPortrait> createState() => _CloudCompanionPortraitState();
}

class _CloudCompanionPortraitState extends State<CloudCompanionPortrait>
    with SingleTickerProviderStateMixin {
  late final greeting = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );
  ui.Image? image;
  bool greeted = false;
  bool get reduced =>
      widget.reduceMotion || MediaQuery.disableAnimationsOf(context);

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final data = await rootBundle.load(cloudCompanionAsset);
      final codec = await ui.instantiateImageCodec(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        targetWidth: 1086,
      );
      try {
        final frame = await codec.getNextFrame();
        if (!mounted) {
          frame.image.dispose();
          return;
        }
        setState(() => image = frame.image);
      } finally {
        codec.dispose();
      }
    } catch (_) {
      // Keep the offline surface usable even when an asset cannot be decoded.
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!greeted) {
      greeted = true;
      if (!reduced) greeting.forward();
    }
    if (reduced) {
      greeting.stop();
      greeting.value = 1;
    }
  }

  @override
  void didUpdateWidget(covariant CloudCompanionPortrait oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.reduceMotion) {
      greeting.stop();
      greeting.value = 1;
    }
  }

  @override
  void dispose() {
    greeting.dispose();
    image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: '小云虚拟人物',
    hint: reduced ? null : '点击让小云挥手',
    button: !reduced,
    child: GestureDetector(
      key: const ValueKey('cloud-companion-portrait'),
      onTap: reduced ? null : () => greeting.forward(from: 0),
      child: SizedBox(
        width: widget.size,
        height: widget.size * 1.1,
        child: AnimatedBuilder(
          animation: greeting,
          builder: (context, _) => image == null
              ? Icon(
                  Icons.cloud_outlined,
                  size: widget.size * .65,
                  color: Theme.of(context).colorScheme.primary,
                )
              : CustomPaint(painter: _CompanionPainter(image!, greeting.value)),
        ),
      ),
    ),
  );
}

class _CompanionPainter extends CustomPainter {
  const _CompanionPainter(this.image, this.progress);
  final ui.Image image;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    canvas.scale(size.width / 600, size.height / 660);
    canvas.translate(-140, -30);
    final paint = Paint()..filterQuality = FilterQuality.high;
    void drawSheet() => canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      const Rect.fromLTWH(0, 0, 2172, 724),
      paint,
    );
    final shoulder = Path()
      ..moveTo(514, 461)
      ..cubicTo(542, 477, 551, 515, 549, 554)
      ..lineTo(545, 606)
      ..lineTo(514, 610)
      ..close();
    canvas.drawPath(
      shoulder,
      Paint()
        ..shader = ui.Gradient.linear(
          const Offset(0, 461),
          const Offset(0, 610),
          const [Color(0xfffffefa), Color(0xffe8f8ff)],
        ),
    );
    canvas.drawPath(
      Path()
        ..moveTo(534, 501)
        ..cubicTo(547, 529, 551, 563, 544, 602),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 10
        ..strokeCap = StrokeCap.round
        ..color = const Color(0xff35b4ee),
    );
    final body = Path()..addRect(const Rect.fromLTWH(140, 437, 600, 250));
    final armCutout = Path()
      ..moveTo(530, 462)
      ..lineTo(650, 462)
      ..lineTo(650, 604)
      ..lineTo(543, 604)
      ..lineTo(548, 554)
      ..lineTo(532, 511)
      ..close();
    canvas.save();
    canvas.clipPath(Path.combine(PathOperation.difference, body, armCutout));
    drawSheet();
    canvas.restore();
    canvas.save();
    canvas.clipRect(const Rect.fromLTWH(140, 20, 600, 442));
    drawSheet();
    canvas.restore();
    final arm = Path()
      ..moveTo(533, 465)
      ..cubicTo(566, 478, 594, 504, 608, 532)
      ..cubicTo(623, 562, 605, 585, 580, 580)
      ..cubicTo(559, 578, 548, 559, 544, 541)
      ..lineTo(529, 495)
      ..close();
    final envelope = math.sin(progress * math.pi);
    final angle = envelope * (-1.5 + math.sin(progress * math.pi * 10) * .25);
    canvas.save();
    canvas.translate(535, 486);
    canvas.rotate(angle);
    canvas.translate(-535, -486);
    canvas.clipPath(arm);
    drawSheet();
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _CompanionPainter old) =>
      old.image != image || old.progress != progress;
}

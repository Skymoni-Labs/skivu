import 'dart:math' as math;
import 'dart:async';
import 'package:flutter/material.dart';
import 'native_social_icons.dart';
import 'state.dart';
import 'native_social_portrait.dart';
import 'ui_plugins.dart';
import 'chat_controls.dart';

/// The contact card's original local call animation. It never starts an engine,
/// accesses the microphone, contacts a platform, or appends a call record.
class SocialNativeCallPreview extends StatefulWidget {
  const SocialNativeCallPreview({
    super.key,
    required this.role,
    required this.onHangUp,
    this.mode = ChatUiMode.wechat,
  });
  final Persona? role;
  final ChatUiMode mode;
  final VoidCallback onHangUp;
  @override
  State<SocialNativeCallPreview> createState() =>
      _SocialNativeCallPreviewState();
}

class _SocialNativeCallPreviewState extends State<SocialNativeCallPreview> {
  Timer? _timer;
  int _elapsed = 0;
  bool _muted = false;
  @override
  void initState() {
    super.initState();
    _start();
  }

  void _start() {
    _timer?.cancel();
    _elapsed = 0;
    _muted = false;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _elapsed++);
    });
  }

  @override
  void didUpdateWidget(SocialNativeCallPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.role?.id != widget.role?.id) _start();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String get _status {
    if (_elapsed < 3) return '等待对方接听…';
    final elapsed = _elapsed - 3;
    return '界面演示 · ${(elapsed ~/ 60).toString().padLeft(2, '0')}:${(elapsed % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xff243e52), Color(0xff527e8d)],
        transform: GradientRotation(20 * math.pi / 180),
      ),
    ),
    child: LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: SizedBox(
          height: math.max(520, constraints.maxHeight),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 42, 20, 25),
            child: Column(
              children: [
                NativeSocialPortrait(
                  mode: widget.mode,
                  persona: widget.role,
                  size: 85,
                  large: true,
                  borderRadius: 20,
                ),
                const SizedBox(height: 24),
                Text(
                  widget.role?.name ?? '未选择角色',
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 24,
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  _status,
                  key: const ValueKey('social-call-preview-status'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xffd8e5eb),
                  ),
                ),
                const SizedBox(height: 14),
                const Text(
                  '本机界面演示，不连接微信或QQ，不发起真实通话。',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 11,
                    color: Color(0xffd8e5eb),
                    height: 1.6,
                  ),
                ),
                if (_muted)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text(
                      '麦克风已静音（本地演示）',
                      style: TextStyle(fontSize: 11, color: Colors.white70),
                    ),
                  ),
                const Spacer(),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _control(
                      '麦克风开关',
                      'mic',
                      () => setState(() => _muted = !_muted),
                      key: const ValueKey('social-call-preview-mic'),
                      active: _muted,
                    ),
                    const SizedBox(width: 40),
                    _control(
                      '挂断通话',
                      'phone',
                      () {
                        _timer?.cancel();
                        widget.onHangUp();
                      },
                      key: const ValueKey('social-call-preview-hangup'),
                      hangup: true,
                    ),
                    const SizedBox(width: 40),
                    _control(
                      '视频通话，开发中',
                      'video',
                      null,
                      key: const ValueKey('social-call-preview-video'),
                    ),
                  ],
                ),
                const SizedBox(height: 9),
                const Text(
                  '视频通话开发中',
                  style: TextStyle(fontSize: 11, color: Colors.white54),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  Widget _control(
    String label,
    String icon,
    VoidCallback? onTap, {
    Key? key,
    bool active = false,
    bool hangup = false,
  }) => Semantics(
    label: label,
    button: true,
    enabled: onTap != null,
    toggled: icon == 'mic' ? active : null,
    child: GestureDetector(
      key: key,
      onTap: onTap,
      child: Container(
        width: 54,
        height: 54,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: hangup
              ? const Color(0xffe56870)
              : Colors.white.withValues(alpha: active ? 0.41 : 0.17),
        ),
        child: Center(
          child: Transform.rotate(
            angle: hangup ? 135 * math.pi / 180 : 0,
            child: NativeSocialIcon(
              icon,
              size: 24,
              color: onTap == null ? Colors.white38 : Colors.white,
            ),
          ),
        ),
      ),
    ),
  );
}

class SocialExtraMenuRow extends StatelessWidget {
  const SocialExtraMenuRow({
    super.key,
    required this.label,
    required this.onTap,
    this.icon,
    this.note,
    this.color = const Color(0xff586e91),
    this.trailing,
    this.enabled = true,
  });
  final String label;
  final String? icon, note;
  final Color color;
  final VoidCallback? onTap;
  final Widget? trailing;
  final bool enabled;
  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    enabled: enabled,
    label: label,
    child: Material(
      color: Colors.white,
      child: InkWell(
        onTap: enabled ? onTap : null,
        child: Container(
          constraints: const BoxConstraints(minHeight: 55),
          padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 15),
          decoration: const BoxDecoration(
            border: Border(
              bottom: BorderSide(color: Color(0xffeeeeee), width: .5),
            ),
          ),
          child: Row(
            children: [
              if (icon != null) ...[
                NativeSocialIcon(
                  icon!,
                  size: 22,
                  color: enabled ? color : Colors.grey,
                ),
                const SizedBox(width: 18),
              ],
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 16,
                    color: enabled ? const Color(0xff191919) : Colors.grey,
                  ),
                ),
              ),
              if (note?.isNotEmpty == true) ...[
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    note!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xff929292),
                    ),
                  ),
                ),
              ],
              const SizedBox(width: 10),
              trailing ??
                  const NativeSocialIcon(
                    'right',
                    size: 16,
                    color: Color(0xffb2b2b2),
                  ),
            ],
          ),
        ),
      ),
    ),
  );
}

class SocialExtraButton extends StatelessWidget {
  const SocialExtraButton({
    super.key,
    required this.label,
    required this.onTap,
    this.color = const Color(0xff07c160),
  });
  final String label;
  final VoidCallback? onTap;
  final Color color;
  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    enabled: onTap != null,
    child: Material(
      color: onTap == null ? const Color(0xffd8dfdc) : color,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    ),
  );
}

/// Original local prototype illustration paths, redrawn with native canvas.
class SocialExtraArt extends StatelessWidget {
  const SocialExtraArt(this.name, {super.key});
  final String name;
  @override
  Widget build(BuildContext context) => Image.asset(
    'assets/social_native/$name.png',
    fit: BoxFit.cover,
    errorBuilder: (_, _, _) => CustomPaint(
      painter: _SocialArtPainter(name),
      child: const SizedBox.expand(),
    ),
  );
}

class SocialNativeProfileForm extends StatefulWidget {
  const SocialNativeProfileForm({
    super.key,
    required this.onDone,
    this.onAvatar,
    this.mode = ChatUiMode.wechat,
  });
  final VoidCallback onDone;
  final Future<void> Function()? onAvatar;
  final ChatUiMode mode;
  @override
  State<SocialNativeProfileForm> createState() =>
      _SocialNativeProfileFormState();
}

class _SocialNativeProfileFormState extends State<SocialNativeProfileForm> {
  static const limits = {'称呼': 24, '社交账号': 36, '个性签名': 100, '地区': 30};
  late final fields = {
    for (final key in limits.keys)
      key: TextEditingController(text: demo.userCard[key] ?? ''),
  };
  bool busy = false;
  String? error;
  @override
  void dispose() {
    for (final field in fields.values) {
      field.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(18),
    children: [
      Center(
        child: AnimatedBuilder(
          animation: demo,
          builder: (_, _) => GestureDetector(
            onTap: widget.onAvatar ?? () => editUserAvatar(context),
            child: Column(
              children: [
                NativeSocialPortrait(
                  mode: widget.mode,
                  user: true,
                  size: 78,
                  large: true,
                  borderRadius: 7,
                ),
                const SizedBox(height: 8),
                const Text(
                  '更换头像',
                  style: TextStyle(fontSize: 12, color: Color(0xff6b8798)),
                ),
              ],
            ),
          ),
        ),
      ),
      const SizedBox(height: 20),
      for (final field in fields.entries)
        Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                field.key == '称呼'
                    ? '名字'
                    : field.key == '社交账号'
                    ? '账号'
                    : field.key,
                style: const TextStyle(fontSize: 12, color: Color(0xff637987)),
              ),
              const SizedBox(height: 7),
              TextField(
                controller: field.value,
                enabled: !busy,
                maxLength: limits[field.key],
                minLines: field.key == '个性签名' ? 3 : 1,
                maxLines: field.key == '个性签名' ? 3 : 1,
                style: const TextStyle(fontSize: 14),
                decoration: InputDecoration(
                  labelText: field.key,
                  counterStyle: const TextStyle(
                    fontSize: 10,
                    color: Color(0xffa0abb4),
                  ),
                  contentPadding: const EdgeInsets.all(12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: const BorderSide(color: Color(0xffdce5eb)),
                  ),
                ),
              ),
            ],
          ),
        ),
      if (error != null)
        Text(error!, style: const TextStyle(fontSize: 12, color: Colors.red)),
      SocialExtraButton(
        label: busy ? '保存中…' : '保存资料',
        onTap: busy
            ? null
            : () async {
                if (fields['称呼']!.text.trim().isEmpty ||
                    fields['社交账号']!.text.trim().isEmpty) {
                  setState(() => error = '请填写名字和账号。');
                  return;
                }
                setState(() => busy = true);
                demo.userCard = {
                  ...demo.userCard,
                  for (final entry in fields.entries)
                    entry.key: entry.value.text.trim(),
                };
                demo.changed();
                await demo.saveChats();
                if (!mounted) return;
                if (demo.storageError != null) {
                  setState(() {
                    error = demo.storageError;
                    busy = false;
                  });
                } else {
                  widget.onDone();
                }
              },
      ),
    ],
  );
}

class _SocialArtPainter extends CustomPainter {
  _SocialArtPainter(this.name);
  final String name;
  @override
  void paint(Canvas canvas, Size size) {
    final colors = switch (name) {
      'flowers' => [0xffe5d8d0, 0xffd2aca8, 0xff9ba793],
      'clouds' => [0xffbfdae8, 0xff9bbfcd, 0xffeff4ee],
      'coffee' => [0xffded3c2, 0xffa2947e, 0xff6e715d],
      'mountain' => [0xffc6d5d1, 0xff93ada6, 0xff607f7b],
      'sunset' => [0xffe7c8b7, 0xffc19c92, 0xff8f9d97],
      _ => [0xffcbdedb, 0xff98b8b5, 0xff688f8e],
    };
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    final scale = math.max(size.width, size.height) / 200;
    canvas.translate(
      (size.width - 200 * scale) / 2,
      (size.height - 200 * scale) / 2,
    );
    canvas.scale(scale);
    void fill(Path path, int color) =>
        canvas.drawPath(path, Paint()..color = Color(color));
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, 200, 200),
      Paint()..color = Color(colors[0]),
    );
    canvas.drawCircle(
      const Offset(148, 46),
      17,
      Paint()..color = const Color(0xffFFF2DC).withValues(alpha: .72),
    );
    final cloud = Path()
      ..moveTo(12, 35)
      ..quadraticBezierTo(27, 25, 42, 35)
      ..quadraticBezierTo(57, 45, 72, 35)
      ..moveTo(80, 68)
      ..quadraticBezierTo(95, 61, 110, 68)
      ..quadraticBezierTo(125, 75, 140, 68);
    canvas.drawPath(
      cloud,
      Paint()
        ..color = Colors.white.withValues(alpha: .34)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
    if (name == 'flowers') {
      final stems = Path()
        ..moveTo(60, 200)
        ..lineTo(78, 62)
        ..moveTo(98, 200)
        ..lineTo(119, 85)
        ..moveTo(145, 200)
        ..lineTo(141, 126);
      canvas.drawPath(
        stems,
        Paint()
          ..color = const Color(0xff8d9b7c)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3,
      );
      for (final bloom in [
        const Offset(79, 68),
        const Offset(122, 94),
        const Offset(143, 132),
      ]) {
        for (final delta in [
          const Offset(-4, -8),
          const Offset(8, -2),
          const Offset(-7, 6),
        ]) {
          canvas.drawCircle(
            bloom + delta,
            13,
            Paint()..color = const Color(0xfff3e9e0),
          );
        }
        canvas.drawCircle(bloom, 5, Paint()..color = const Color(0xffcbaf77));
      }
    } else if (name == 'coffee') {
      fill(
        Path()
          ..moveTo(0, 130)
          ..lineTo(200, 100)
          ..lineTo(200, 200)
          ..lineTo(0, 200)
          ..close(),
        0xffaa9e87,
      );
      canvas.save();
      canvas.translate(20, 112);
      canvas.rotate(-13 * math.pi / 180);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(0, 0, 70, 45),
          const Radius.circular(2),
        ),
        Paint()..color = const Color(0xffe9e3d4),
      );
      canvas.restore();
      canvas.drawPath(
        Path()
          ..moveTo(116, 86)
          ..lineTo(159, 86)
          ..lineTo(159, 127)
          ..cubicTo(159, 147, 116, 147, 116, 127)
          ..close(),
        Paint()..color = const Color(0xfff5eee4),
      );
      canvas.drawOval(
        Rect.fromCenter(center: const Offset(138, 87), width: 44, height: 14),
        Paint()..color = const Color(0xffe7d8c6),
      );
      canvas.drawOval(
        Rect.fromCenter(center: const Offset(138, 87), width: 34, height: 10),
        Paint()..color = const Color(0xff8d7460),
      );
      canvas.drawPath(
        Path()
          ..moveTo(159, 92)
          ..cubicTo(184, 88, 184, 121, 159, 118),
        Paint()
          ..color = const Color(0xfff5eee4)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 8,
      );
    } else {
      fill(
        Path()
          ..moveTo(0, 111)
          ..lineTo(51, 64)
          ..lineTo(116, 129)
          ..lineTo(163, 84)
          ..lineTo(200, 103)
          ..lineTo(200, 200)
          ..lineTo(0, 200)
          ..close(),
        colors[1],
      );
      fill(
        Path()
          ..moveTo(0, 150)
          ..lineTo(69, 119)
          ..lineTo(122, 148)
          ..lineTo(200, 120)
          ..lineTo(200, 200)
          ..lineTo(0, 200)
          ..close(),
        colors[2],
      );
      fill(
        Path()
          ..moveTo(0, 163)
          ..quadraticBezierTo(40, 151, 100, 163)
          ..quadraticBezierTo(160, 175, 200, 163)
          ..lineTo(200, 200)
          ..lineTo(0, 200)
          ..close(),
        0x73dce8df,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SocialArtPainter oldDelegate) => oldDelegate.name != name;
}

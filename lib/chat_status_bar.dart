import 'package:flutter/material.dart';
import 'state.dart';

/// Compact usage readout below the composer; missing provider data uses a dash.
class ChatStatusBar extends StatelessWidget {
  const ChatStatusBar({super.key, required this.conversation});

  final Conversation conversation;

  @override
  Widget build(BuildContext context) {
    final usage = conversation.usage;
    final rounds = conversation.messages
        .where((message) => message.user)
        .length;
    final color = Theme.of(context).brightness == Brightness.dark
        ? const Color(0xffacb5c0)
        : muted;
    return DefaultTextStyle.merge(
      style: TextStyle(fontSize: 10, height: 1.4, color: color),
      child: Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 14,
        runSpacing: 4,
        children: [
          _item(
            '当前会话轮次、执行步数与生成速度；— 表示暂无统计',
            Icon(Icons.speed_outlined, size: 13, color: color),
            '$rounds 轮 ${_count(usage.steps)} 步 · '
                '${_speed(usage.tokensPerSecond)} tok/s',
          ),
          _item(
            '当前会话 Token 用量与缓存命中率；— 表示暂无统计',
            CustomPaint(
              size: const Size(12, 13),
              painter: _TokenStackPainter(color),
            ),
            '${_count(usage.totalTokens)} tok · '
                '缓存命中 ${_percent(usage.cacheHitRate)}',
          ),
          _item(
            '上下文占用；— 表示暂无统计',
            SizedBox.square(
              dimension: 11,
              child: CircularProgressIndicator(
                value: _ratio(usage.contextUsage) ?? 0,
                strokeWidth: 1.7,
                color: color,
                backgroundColor: color.withValues(alpha: .25),
              ),
            ),
            _percent(usage.contextUsage),
          ),
        ],
      ),
    );
  }

  Widget _item(String hint, Widget icon, String text) => Tooltip(
    message: hint,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        icon,
        const SizedBox(width: 5),
        Flexible(child: Text(text)),
      ],
    ),
  );

  static String _count(int? value) {
    if (value == null || value < 0) return '—';
    if (value >= 1000000) return '${(value / 1000000).toStringAsFixed(1)}M';
    if (value >= 1000) return '${(value / 1000).toStringAsFixed(1)}k';
    return '$value';
  }

  static String _speed(double? value) =>
      value == null || !value.isFinite || value < 0
      ? '—'
      : value.toStringAsFixed(value == value.roundToDouble() ? 0 : 1);

  static double? _ratio(double? value) =>
      value == null || !value.isFinite || value < 0 || value > 1 ? null : value;

  static String _percent(double? value) {
    final ratio = _ratio(value);
    return ratio == null ? '—' : '${(ratio * 100).round()}%';
  }
}

class _TokenStackPainter extends CustomPainter {
  const _TokenStackPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final top = Rect.fromLTWH(.5, .5, size.width - 1, 4);
    canvas.drawOval(top, paint);
    final path = Path()
      ..moveTo(.5, 2.5)
      ..lineTo(.5, size.height - 2.5)
      ..arcToPoint(
        Offset(size.width - .5, size.height - 2.5),
        radius: Radius.elliptical((size.width - 1) / 2, 2),
        clockwise: false,
      )
      ..lineTo(size.width - .5, 2.5);
    canvas.drawPath(path, paint);
    canvas.drawArc(
      top.shift(const Offset(0, 4)),
      0,
      3.141592653589793,
      false,
      paint,
    );
  }

  @override
  bool shouldRepaint(_TokenStackPainter oldDelegate) =>
      oldDelegate.color != color;
}

import 'package:flutter/material.dart';
import 'state.dart';
import 'product_ui.dart';

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
    if (conversation.messages.isEmpty) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.centerRight,
      child: TextButton.icon(
        key: const ValueKey('conversation-statistics'),
        style: TextButton.styleFrom(
          visualDensity: VisualDensity.compact,
          minimumSize: const Size(0, 24),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
          textStyle: const TextStyle(fontSize: 11),
        ),
        onPressed: () => showMarketDetails(
          context,
          name: '会话统计',
          description: '查看这段对话的用量与生成速度。缺少服务商统计时显示“暂无数据”。',
          icon: MarketGlyph(
            icon: Icons.insights_rounded,
            color: Theme.of(context).colorScheme.primary,
          ),
          details: [
            ('对话轮次', '$rounds 轮'),
            ('执行步数', _count(usage.steps)),
            (
              '生成速度',
              usage.tokensPerSecond == null
                  ? '暂无数据'
                  : '${_speed(usage.tokensPerSecond)} Token / 秒',
            ),
            ('Token 用量', _count(usage.totalTokens)),
            ('缓存命中率', _percent(usage.cacheHitRate)),
            ('上下文占用', _percent(usage.contextUsage)),
          ],
        ),
        icon: const Icon(Icons.insights_rounded, size: 14),
        label: const Text('会话信息'),
      ),
    );
  }

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

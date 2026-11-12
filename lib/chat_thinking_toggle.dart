import 'package:flutter/material.dart';
import 'state.dart';
import 'widgets.dart' show toast;

class ChatThinkingToggle extends StatefulWidget {
  const ChatThinkingToggle({super.key, this.store});

  final DemoStore? store;

  @override
  State<ChatThinkingToggle> createState() => _ChatThinkingToggleState();
}

class _ChatThinkingToggleState extends State<ChatThinkingToggle> {
  bool saving = false;
  DemoStore get store => widget.store ?? demo;

  Future<void> toggle() async {
    final current = store.activeConnection;
    if (saving ||
        store.models.thinkingUpdatePending ||
        store.streaming ||
        store.useAccount ||
        store.useBeta ||
        current?.supportsThinking != true) {
      return;
    }
    setState(() => saving = true);
    try {
      await store.models.setThinkingEnabled(
        current!.id,
        !current.effectiveThinkingEnabled!,
      );
    } catch (_) {
      if (mounted) toast(context, '思考设置未保存，请重试');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: store,
    builder: (context, _) {
      final connection = store.activeConnection;
      final supported =
          !store.useAccount &&
          !store.useBeta &&
          connection?.supportsThinking == true;
      final selected = supported && connection!.effectiveThinkingEnabled!;
      final updating = saving || store.models.thinkingUpdatePending;
      final enabled = supported && !store.streaming && !updating;
      final message = !supported
          ? '当前连接暂未适配思考开关'
          : updating
          ? '正在保存思考设置'
          : store.streaming
          ? '本次运行结束后可切换深度思考'
          : connection!.thinkingEnabled == null
          ? '跟随服务商默认，深度思考已开启'
          : selected
          ? '深度思考已开启，点击关闭'
          : '深度思考已关闭，点击开启';
      final colors = Theme.of(context).colorScheme;
      return Tooltip(
        message: message,
        child: Semantics(
          toggled: selected,
          enabled: enabled,
          child: TextButton.icon(
            key: const ValueKey('chat-thinking-toggle'),
            onPressed: enabled ? toggle : null,
            style: TextButton.styleFrom(
              foregroundColor: selected
                  ? colors.primary
                  : colors.onSurfaceVariant,
              backgroundColor: selected
                  ? colors.primary.withValues(alpha: .1)
                  : Colors.transparent,
              side: BorderSide(
                color: selected
                    ? colors.primary.withValues(alpha: .42)
                    : colors.outline.withValues(alpha: .3),
              ),
              shape: const StadiumBorder(),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              minimumSize: const Size(0, 32),
              visualDensity: VisualDensity.compact,
              textStyle: Theme.of(
                context,
              ).textTheme.labelMedium?.copyWith(fontSize: 12),
            ),
            icon: const Icon(Icons.psychology_outlined, size: 16),
            label: const Text('深度思考'),
          ),
        ),
      );
    },
  );
}

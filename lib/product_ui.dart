import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'glass.dart' show AuroraBackdrop;
import 'state.dart' show demo;
import 'plugin_market_widgets.dart';

export 'plugin_market_widgets.dart';

class ProductScaffold extends StatelessWidget {
  const ProductScaffold({
    super.key,
    required this.title,
    required this.body,
    this.actions = const [],
  });
  final String title;
  final Widget body;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Scaffold(
    extendBodyBehindAppBar: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    appBar: AppBar(
      systemOverlayStyle: SystemUiOverlayStyle(
        statusBarIconBrightness: demo.dark ? Brightness.light : Brightness.dark,
        statusBarBrightness: demo.dark ? Brightness.dark : Brightness.light,
      ),
      title: Text(
        title,
        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
      ),
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      actions: actions,
    ),
    body: Stack(
      children: [
        Positioned.fill(child: AuroraBackdrop(dark: demo.dark)),
        Padding(
          padding: EdgeInsets.only(
            top: MediaQuery.paddingOf(context).top + kToolbarHeight,
          ),
          child: SafeArea(
            top: false,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 800),
                child: body,
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

class ProductSection extends StatelessWidget {
  const ProductSection({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    required this.children,
  });
  final String title;
  final String? subtitle;
  final IconData? icon;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: MarketPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                Icon(
                  icon,
                  size: 21,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 7),
            Text(
              subtitle!,
              style: TextStyle(
                fontSize: 13,
                height: 1.6,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          if (children.isNotEmpty) const SizedBox(height: 14),
          ...children,
        ],
      ),
    ),
  );
}

class ProductEmpty extends StatelessWidget {
  const ProductEmpty({
    super.key,
    required this.title,
    required this.description,
    this.icon = Icons.folder_open_rounded,
  });
  final String title, description;
  final IconData icon;
  @override
  Widget build(BuildContext context) => MarketPanel(
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 22),
      child: Column(
        children: [
          MarketGlyph(icon: icon, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 16),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            description,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              height: 1.65,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    ),
  );
}

class ProductError extends StatelessWidget {
  const ProductError({
    super.key,
    required this.message,
    required this.detail,
    this.onRetry,
  });
  final String message, detail;
  final VoidCallback? onRetry;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: MarketPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            message,
            style: TextStyle(
              color: Theme.of(context).colorScheme.error,
              height: 1.6,
            ),
          ),
          if (onRetry != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('重试'),
              ),
            ),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('查看详细原因', style: TextStyle(fontSize: 12)),
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: SelectableText(
                  detail,
                  style: const TextStyle(fontSize: 12, height: 1.6),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

String programStateLabel(Object? state) =>
    const {
      'queued': '等待中',
      'pending': '等待中',
      'starting': '正在启动',
      'running': '运行中',
      'paused': '已暂停',
      'completed': '已完成',
      'succeeded': '已完成',
      'finished': '已结束',
      'exited': '已结束',
      'failed': '未完成',
      'stopped': '已停止',
      'cancelled': '已取消',
      'interrupted': '已中断',
      'unknown': '状态待确认',
    }[state] ??
    '状态待确认';

String programKindLabel(Object? backend) => switch (backend) {
  'adb' || 'android' => '手机任务',
  'linux' => '编程任务',
  _ => '运行任务',
};

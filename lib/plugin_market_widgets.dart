import 'package:flutter/material.dart';

/// Shared presentation for the market's different package formats.
class MarketPanel extends StatelessWidget {
  const MarketPanel({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(18),
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: dark
          ? Theme.of(context).colorScheme.surface.withValues(alpha: .85)
          : Colors.white.withValues(alpha: .78),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: BorderSide(
          color: Colors.white.withValues(alpha: dark ? .10 : .70),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

class MarketHeader extends StatelessWidget {
  const MarketHeader({
    super.key,
    required this.title,
    required this.subtitle,
    this.actions = const [],
  });

  final String title, subtitle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w700,
                letterSpacing: -.6,
              ),
            ),
          ),
          ...actions,
        ],
      ),
      const SizedBox(height: 6),
      Text(
        subtitle,
        style: TextStyle(
          fontSize: 13,
          height: 1.6,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    ],
  );
}

class MarketGlyph extends StatelessWidget {
  const MarketGlyph({
    super.key,
    required this.icon,
    required this.color,
    this.size = 52,
  });

  final IconData icon;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [color.withValues(alpha: .08), color.withValues(alpha: .18)],
      ),
      borderRadius: BorderRadius.circular(size * .30),
    ),
    child: Icon(icon, color: color, size: size * .48),
  );
}

class MarketBadge extends StatelessWidget {
  const MarketBadge(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.primary.withValues(alpha: .09),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    ),
  );
}

class MarketAction extends StatelessWidget {
  const MarketAction({
    super.key,
    required this.label,
    required this.onPressed,
    this.busy = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) => FilledButton.tonal(
    onPressed: onPressed,
    style: FilledButton.styleFrom(
      minimumSize: const Size(72, 40),
      padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 10),
      textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      shape: const StadiumBorder(),
    ),
    child: busy
        ? const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Text(label),
  );
}

InputDecoration marketSearchDecoration(BuildContext context, String hint) =>
    InputDecoration(
      hintText: hint,
      prefixIcon: const Icon(Icons.search_rounded, size: 22),
      filled: true,
      fillColor: Theme.of(context).brightness == Brightness.dark
          ? Theme.of(context).colorScheme.surface.withValues(alpha: .75)
          : Colors.white.withValues(alpha: .45),
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide.none,
      ),
    );

Future<void> showMarketDetails(
  BuildContext context, {
  required String name,
  required String description,
  required Widget icon,
  required List<(String, String)> details,
  String? guidance,
  List<Widget> actions = const [],
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  backgroundColor: Theme.of(context).colorScheme.surface.withValues(alpha: 1),
  builder: (context) => ConstrainedBox(
    constraints: BoxConstraints(
      maxHeight: MediaQuery.sizeOf(context).height * .82,
    ),
    child: SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        24,
        8,
        24,
        24 + MediaQuery.paddingOf(context).bottom,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              icon,
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  name,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              IconButton(
                tooltip: '关闭详情',
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Text(description, style: const TextStyle(fontSize: 14, height: 1.7)),
          if (guidance != null) ...[
            const SizedBox(height: 16),
            Text(guidance, style: const TextStyle(fontSize: 13, height: 1.7)),
          ],
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Divider(height: 1),
          ),
          for (final (label, value) in details)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 4),
                  SelectableText(value, style: const TextStyle(fontSize: 14)),
                ],
              ),
            ),
          if (actions.isNotEmpty)
            Wrap(spacing: 8, runSpacing: 8, children: actions),
        ],
      ),
    ),
  ),
);

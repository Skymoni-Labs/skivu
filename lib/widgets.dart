import 'package:flutter/material.dart';
import 'state.dart';
import 'glass.dart';

Widget label(
  String text, {
  double size = 14,
  Color? color,
  FontWeight? weight,
  double? height,
}) => Text(
  text,
  style: TextStyle(
    fontSize: size,
    color: ink,
    fontWeight: weight,
    height: height ?? 1.65,
  ),
);

class TinyTag extends StatelessWidget {
  const TinyTag(this.text, {super.key, this.color});
  final String text;
  final Color? color;
  Color get _color => color ?? green;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: _color.withValues(alpha: .09),
      borderRadius: BorderRadius.circular(6),
    ),
    child: label(text, size: 10, color: _color),
  );
}

class Pane extends StatelessWidget {
  const Pane({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(22),
    this.color,
  });
  final Widget child;
  final EdgeInsets padding;
  final Color? color;
  @override
  Widget build(BuildContext context) => GlassSurface(
    opacity: .60,
    child: Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color?.withValues(alpha: .32),
        borderRadius: BorderRadius.circular(20),
      ),
      child: child,
    ),
  );
}

class PageHeading extends StatelessWidget {
  const PageHeading(
    this.eyebrow,
    this.title,
    this.description, {
    super.key,
    this.action,
  });
  final String eyebrow, title, description;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 22),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 18,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            label(title, size: 23, weight: FontWeight.w600),
            if (action != null) action!,
          ],
        ),
        const SizedBox(height: 8),
        label(description, color: muted, size: 12),
      ],
    ),
  );
}

Widget actionButton(
  String title,
  IconData icon,
  VoidCallback action, {
  bool filled = false,
}) => filled
    ? FilledButton.icon(
        onPressed: action,
        icon: Icon(icon, size: 17),
        label: Text(title),
      )
    : OutlinedButton.icon(
        onPressed: action,
        icon: Icon(icon, size: 17),
        label: Text(title),
      );

void toast(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
        width: MediaQuery.sizeOf(context).width > 600 ? 440 : null,
      ),
    );

void navigate(BuildContext context, String route) {
  Navigator.of(context).pushNamed(route);
}

class SettingRow extends StatelessWidget {
  const SettingRow(
    this.title,
    this.detail, {
    super.key,
    this.trailing,
    this.icon,
    this.onTap,
  });
  final String title, detail;
  final Widget? trailing;
  final IconData? icon;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => InkWell(
    borderRadius: BorderRadius.circular(12),
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 6),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 21, color: green),
            const SizedBox(width: 16),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                label(title, weight: FontWeight.w500),
                label(detail, size: 12, color: muted),
              ],
            ),
          ),
          const SizedBox(width: 12),
          trailing ?? Icon(Icons.chevron_right, color: muted, size: 18),
        ],
      ),
    ),
  );
}

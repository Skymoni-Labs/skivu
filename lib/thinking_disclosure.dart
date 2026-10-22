import 'package:flutter/material.dart';
import 'state.dart' show ink;

/// Reasoning belongs above the reply, with no card or tinted tile behind it.
class ThinkingDisclosure extends StatefulWidget {
  const ThinkingDisclosure({super.key, required this.text});
  final String text;
  @override
  State<ThinkingDisclosure> createState() => _ThinkingDisclosureState();
}

class _ThinkingDisclosureState extends State<ThinkingDisclosure> {
  bool expanded = false;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      TextButton.icon(
        key: const ValueKey('thinking-toggle'),
        style: TextButton.styleFrom(
          foregroundColor: ink,
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
          minimumSize: const Size(0, 36),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          backgroundColor: Colors.transparent,
          alignment: Alignment.centerLeft,
        ),
        onPressed: () => setState(() => expanded = !expanded),
        icon: Icon(
          expanded ? Icons.expand_more : Icons.chevron_right,
          size: 17,
        ),
        label: const Text('思考过程', style: TextStyle(fontSize: 12)),
      ),
      if (expanded)
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 4, 4, 14),
          child: SelectableText(
            widget.text,
            style: const TextStyle(fontSize: 12, height: 1.6, color: ink),
          ),
        ),
    ],
  );
}

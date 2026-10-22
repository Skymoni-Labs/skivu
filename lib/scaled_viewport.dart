import 'package:flutter/material.dart';

/// Scale layout and hit testing together, including system and keyboard insets.
class ScaledViewport extends StatelessWidget {
  const ScaledViewport({super.key, required this.scale, required this.child});
  final double scale;
  final Widget child;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final media = MediaQuery.of(context);
      return ClipRect(
        child: OverflowBox(
          alignment: Alignment.topLeft,
          minWidth: bounds.maxWidth / scale,
          maxWidth: bounds.maxWidth / scale,
          minHeight: bounds.maxHeight / scale,
          maxHeight: bounds.maxHeight / scale,
          child: Transform.scale(
            scale: scale,
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: bounds.maxWidth / scale,
              height: bounds.maxHeight / scale,
              child: MediaQuery(
                data: media.copyWith(
                  size: Size(bounds.maxWidth / scale, bounds.maxHeight / scale),
                  padding: media.padding / scale,
                  viewPadding: media.viewPadding / scale,
                  viewInsets: media.viewInsets / scale,
                ),
                child: child,
              ),
            ),
          ),
        ),
      );
    },
  );
}

import 'package:flutter/widgets.dart';

/// Report the space actually assigned by Scaffold after Android IME resizing.
/// Browser viewport units can lag behind these bounds in embedded WebViews.
class UiDocumentViewport extends StatefulWidget {
  const UiDocumentViewport({
    super.key,
    required this.onResize,
    required this.child,
  });
  final ValueChanged<Size> onResize;
  final Widget child;

  @override
  State<UiDocumentViewport> createState() => _UiDocumentViewportState();
}

class _UiDocumentViewportState extends State<UiDocumentViewport> {
  Size? _size;
  bool _queued = false;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final size = constraints.biggest;
      if (size.isFinite && size != _size) {
        _size = size;
        if (!_queued) {
          _queued = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _queued = false;
            if (mounted) widget.onResize(_size!);
          });
        }
      }
      return widget.child;
    },
  );
}

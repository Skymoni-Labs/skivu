import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'ui_document_port.dart';

Widget buildUiDocument({
  required UiCommand onCommand,
  required UiReady onReady,
}) => _NativeDocument(onCommand: onCommand, onReady: onReady);

class _NativeDocument extends StatefulWidget {
  const _NativeDocument({required this.onCommand, required this.onReady});
  final UiCommand onCommand;
  final UiReady onReady;
  @override
  State<_NativeDocument> createState() => _NativeDocumentState();
}

class _NativeDocumentState extends State<_NativeDocument> {
  late final WebViewController controller;
  @override
  void initState() {
    super.initState();
    controller = WebViewController()
      ..setBackgroundColor(Colors.transparent)
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'SkivuNative',
        onMessageReceived: (message) {
          if (message.message.length > 3000000) return;
          try {
            final value = jsonDecode(message.message);
            if (value is Map<String, dynamic>) widget.onCommand(value);
          } catch (_) {}
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            final uri = Uri.tryParse(request.url);
            return uri?.scheme == 'file' &&
                    uri!.path.endsWith(
                      '/flutter_assets/assets/social_ui/index.html',
                    )
                ? NavigationDecision.navigate
                : NavigationDecision.prevent;
          },
          onPageFinished: (_) => widget.onReady((value) async {
            if (!mounted) return;
            await controller.runJavaScript(
              'window.SkivuHost?.receive(JSON.parse(${jsonEncode(jsonEncode(value))}));',
            );
          }),
        ),
      )
      ..loadFlutterAsset('assets/social_ui/index.html');
  }

  @override
  Widget build(BuildContext context) => WebViewWidget(controller: controller);
}

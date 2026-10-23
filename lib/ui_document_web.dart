import 'dart:js_interop';
import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;
import 'ui_document_port.dart';

Widget buildUiDocument({
  required UiCommand onCommand,
  required UiReady onReady,
}) => _WebDocument(onCommand: onCommand, onReady: onReady);

class _WebDocument extends StatefulWidget {
  const _WebDocument({required this.onCommand, required this.onReady});
  final UiCommand onCommand;
  final UiReady onReady;
  @override
  State<_WebDocument> createState() => _WebDocumentState();
}

class _WebDocumentState extends State<_WebDocument> {
  web.HTMLIFrameElement? frame;
  late final JSFunction listener;
  final origin = Uri.base.origin;
  @override
  void initState() {
    super.initState();
    listener = ((web.Event event) {
      final message = event as web.MessageEvent;
      if (message.origin != origin ||
          frame == null ||
          message.source != frame!.contentWindow)
        return;
      final raw = message.data.dartify();
      if (raw is! Map ||
          raw['type'] != 'skivu-ui-command' ||
          raw['payload'] is! Map)
        return;
      widget.onCommand(Map<String, dynamic>.from(raw['payload'] as Map));
    }).toJS;
    web.window.addEventListener('message', listener);
  }

  @override
  void dispose() {
    web.window.removeEventListener('message', listener);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => HtmlElementView.fromTagName(
    tagName: 'iframe',
    onElementCreated: (element) {
      final value = element as web.HTMLIFrameElement;
      frame = value;
      value.title = 'Skivu 共用角色与会话的界面插件';
      value.allow = 'camera; microphone; display-capture';
      value.style
        ..border = '0'
        ..width = '100%'
        ..height = '100%';
      value.src = Uri.base
          .resolve('assets/assets/social_ui/index.html')
          .toString();
      widget.onReady((snapshot) async {
        if (mounted)
          value.contentWindow?.postMessage(
            {'type': 'skivu-ui-state', 'payload': snapshot}.jsify(),
            origin.toJS,
          );
      });
    },
  );
}

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/native_social_media.dart';

Map<String, dynamic> attachment({
  String kind = 'file',
  String mime = 'application/pdf',
  String name = '文档.pdf',
  List<int> bytes = const [1, 2, 3],
}) => {
  'id': 'native-attachment-test',
  'kind': kind,
  'created': '2026-10-24T12:00:00',
  'user': true,
  'payload': {'name': name, 'data': 'data:$mime;base64,${base64Encode(bytes)}'},
};

void main() {
  const channel = MethodChannel('skivu/chat_attachment');

  test(
    'attachment projection validates kind MIME size and canonical safe names',
    () {
      final result = NativeChatAttachment.parse(attachment(name: '../CON.exe'));
      expect(result.mime, 'application/pdf');
      expect(result.name, endsWith('.pdf'));
      expect(result.name, isNot(contains('/')));
      expect(result.name, isNot(startsWith('.')));
      expect(
        NativeChatAttachment.parse(attachment(name: 'CON.pdf')).name,
        'chat-CON.pdf',
      );
      expect(result.bytes, orderedEquals([1, 2, 3]));
      expect(
        () => NativeChatAttachment.parse(
          attachment(mime: 'application/vnd.android.package-archive'),
        ),
        throwsFormatException,
      );
      expect(
        () => NativeChatAttachment.parse(attachment(kind: 'image')),
        throwsFormatException,
      );
      expect(
        () => NativeChatAttachment.parse(attachment(bytes: [])),
        throwsFormatException,
      );
      expect(
        () => NativeChatAttachment.parse(
          attachment(bytes: List.filled(2 * 1024 * 1024 + 1, 1)),
        ),
        throwsFormatException,
      );
    },
  );

  Future<void> mount(
    WidgetTester tester,
    Future<void> Function(BuildContext) action,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () => action(context),
              child: const Text('执行'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('执行'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'Android system open receives bounded bytes and sanitized explicit MIME',
    (tester) async {
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        return true;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      await mount(
        tester,
        (context) =>
            openNativeChatAttachment(context, attachment(name: 'report.exe')),
      );
      expect(calls.single.method, 'open');
      expect(calls.single.arguments['mime'], 'application/pdf');
      expect(calls.single.arguments['name'], 'report.pdf');
      expect(calls.single.arguments['bytes'], orderedEquals([1, 2, 3]));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Android save cancellation completes normally without a success message',
    (tester) async {
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        return false;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      await mount(
        tester,
        (context) => saveNativeChatAttachment(
          context,
          attachment(kind: 'video', mime: 'video/mp4', name: 'video.mp4'),
        ),
      );
      expect(calls.single.method, 'save');
      expect(calls.single.arguments['mime'], 'video/mp4');
      expect(find.byType(SnackBar), findsNothing);
    },
  );

  testWidgets('save failure and missing viewer produce actionable feedback', (
    tester,
  ) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async => throw PlatformException(
        code: call.method == 'open' ? 'NO_VIEWER' : 'SAVE_FAILED',
      ),
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    await mount(
      tester,
      (context) => openNativeChatAttachment(context, attachment()),
    );
    expect(find.text('未找到可打开此附件的应用，请先另存。'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await mount(
      tester,
      (context) => saveNativeChatAttachment(context, attachment()),
    );
    expect(find.text('附件未保存，请检查所选位置后重试。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('invalid archive attachment never reaches native code', (
    tester,
  ) async {
    int calls = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      _,
    ) async {
      calls++;
      return true;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    await mount(
      tester,
      (context) =>
          openNativeChatAttachment(context, attachment(mime: 'text/html')),
    );
    expect(calls, 0);
    expect(find.text('附件格式不正确或超过 2MB。'), findsOneWidget);
  });

  testWidgets('unsupported system open on desktop offers the save action', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    await mount(
      tester,
      (context) => openNativeChatAttachment(context, attachment()),
    );
    expect(find.text('此平台暂不支持系统打开附件，可选择另存。'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
    expect(tester.takeException(), isNull);
  });
}

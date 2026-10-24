import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ski/chat_extras.dart';
import 'package:ski/state.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAGUlEQVR4nGN0aDjCQApgIkn1qIZRDUNKAwDVAAGkxqTHVQAAAABJRU5ErkJggg==',
);
Future<BuildContext> _open(WidgetTester tester) async {
  late BuildContext host;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) {
            host = context;
            return const SizedBox();
          },
        ),
      ),
    ),
  );
  return host;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    demo.conversations
      ..clear()
      ..add(
        Conversation('媒体测试', [], personaId: demo.personas.first.id)
          ..confirmBeforeReply = true,
      );
    demo.conversation = 0;
  });
  testWidgets(
    'album entry is one sheet, cancellation has no picker or send side effect',
    (tester) async {
      final host = await _open(tester);
      var calls = 0;
      final done = showChatMediaActions(
        host,
        picker: (_) async {
          calls++;
          return null;
        },
      );
      await tester.pumpAndSettle();
      for (final label in ['从相册选择', '拍摄照片', '语音描述']) {
        expect(find.text(label), findsOneWidget);
      }
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(SegmentedButton<bool>), findsNothing);
      Navigator.pop(host);
      await tester.pumpAndSettle();
      expect(await done, isFalse);
      expect(calls, 0);
      expect(demo.messages, isEmpty);
    },
  );
  testWidgets(
    'gallery and camera dispatch to the system source without an editor',
    (tester) async {
      final host = await _open(tester);
      final calls = <ImageSource>[];
      for (final source in ImageSource.values) {
        final done = showChatMediaActions(
          host,
          picker: (value) async {
            calls.add(value);
            return null;
          },
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.text(source == ImageSource.gallery ? '从相册选择' : '拍摄照片'),
        );
        await tester.pumpAndSettle();
        expect(await done, isFalse);
        expect(calls.last, source);
        expect(find.byType(AlertDialog), findsNothing);
      }
      expect(demo.messages, isEmpty);
    },
  );
  testWidgets('a confirmed system photo joins the pending batch directly', (
    tester,
  ) async {
    final host = await _open(tester);
    final sent = await tester.runAsync(
      () => sendSystemChatPhoto(
        host,
        source: ImageSource.camera,
        picker: (_) async => _png,
      ),
    );
    await tester.pumpAndSettle();
    expect(sent, isTrue);
    expect(demo.messages, hasLength(1));
    final message = demo.messages.single;
    expect(message.kind, 'image');
    expect(message.status, 'queued');
    expect(message.described, isFalse);
    expect(message.imageData, startsWith('data:image/png;base64,'));
    expect(find.byType(AlertDialog), findsNothing);
  });
  testWidgets(
    'switching conversations while the camera is open cannot send to either chat',
    (tester) async {
      final host = await _open(tester);
      final pending = Completer<List<int>?>();
      final first = demo.conversations.first;
      final done = sendSystemChatPhoto(
        host,
        source: ImageSource.camera,
        picker: (_) async {
          final raw = await pending.future;
          return raw == null ? null : base64Decode(base64Encode(raw));
        },
      );
      demo.conversations.add(
        Conversation('另一段对话', [], personaId: demo.personas.first.id)
          ..confirmBeforeReply = true,
      );
      demo.conversation = 1;
      pending.complete(_png);
      expect(await tester.runAsync(() => done), isFalse);
      await tester.pumpAndSettle();
      expect(first.messages, isEmpty);
      expect(demo.messages, isEmpty);
      expect(find.text('对话已切换，请重新选择照片。'), findsOneWidget);
    },
  );
  testWidgets(
    'voice description opens a single form and remains a voice message',
    (tester) async {
      final host = await _open(tester);
      final done = showChatMediaActions(host);
      await tester.pumpAndSettle();
      await tester.tap(find.text('语音描述'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.byType(SegmentedButton<bool>), findsNothing);
      expect(find.text('开始语音识别'), findsNothing);
      await tester.enterText(find.byType(TextField), '晚安，明天见。');
      await tester.tap(find.text('加入待发送'));
      await tester.pumpAndSettle();
      expect(await done, isTrue);
      expect(demo.messages.single.kind, 'voice');
      expect(demo.messages.single.described, isTrue);
      expect(demo.messages.single.text, '晚安，明天见。');
    },
  );
}

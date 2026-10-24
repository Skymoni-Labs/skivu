import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/settings_home.dart';

void main() {
  testWidgets('file import shows counts without rendering private JSON', (
    tester,
  ) async {
    final raw = jsonEncode({
      'schema': 'skivu-chats-v1',
      'conversations': [
        {
          'messages': [
            {'text': 'PRIVATE_FIXTURE_CONTENT'},
            {'text': 'another'},
          ],
        },
      ],
      'personas': [
        {'name': 'PRIVATE_FIXTURE_NAME'},
      ],
      'worlds': [],
    });
    await tester.pumpWidget(
      MaterialApp(home: ChatBackupImportDialog(initialText: raw)),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('1 段对话 · 2 条消息'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.textContaining('PRIVATE_FIXTURE_CONTENT'), findsNothing);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '确认恢复'))
          .onPressed,
      isNotNull,
    );
  });
  testWidgets(
    'invalid file cannot replace records and clipboard remains available',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: ChatBackupImportDialog(initialText: 'not json'),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('不符合 Skivu'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '确认恢复'))
            .onPressed,
        isNull,
      );
      await tester.pumpWidget(
        const MaterialApp(
          home: ChatBackupImportDialog(key: ValueKey('clipboard')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
    },
  );
}

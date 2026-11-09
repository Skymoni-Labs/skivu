import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/cloud_coding_tools.dart';
import 'package:ski/cloud_file_card.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Open dispatches to the native phone app and shows the actual saved path',
    (tester) async {
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(cloudExecutionChannel, (call) async {
            calls.add(call.method);
            if (call.method == 'artifacts.page')
              return {
                'items': [
                  {
                    'id': 'artifact_${'a' * 32}',
                    'name': 'blank.xlsx',
                    'format': 'xlsx',
                    'bytes': 2040,
                    'version': 1,
                    'sheets': 1,
                    'state': 'delivered',
                    'phoneSaveState': 'saved',
                    'phonePath': 'Download/Skivu/blank.xlsx',
                  },
                ],
                'total': 1,
                'nextOffset': null,
              };
            return {'state': 'opened'};
          });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: CloudFileCard(ids: ['artifact_${'a' * 32}'])),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Download/Skivu/blank.xlsx'), findsOneWidget);
      expect(find.text('最终成果 · 1 个文件'), findsOneWidget);
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      expect(calls, contains('artifact.open'));
      expect(calls, isNot(contains('artifact.preview')));
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(cloudExecutionChannel, null);
    },
  );
  testWidgets(
    'An app-private file never claims to have been saved to phone Downloads',
    (tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            cloudExecutionChannel,
            (call) async => {
              'items': [
                {
                  'id': 'artifact_${'b' * 32}',
                  'name': 'draft.xlsx',
                  'format': 'xlsx',
                  'bytes': 2040,
                  'version': 1,
                  'state': 'delivered',
                  'phoneSaveState': 'failed',
                },
              ],
              'total': 1,
              'nextOffset': null,
            },
          );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: CloudFileCard(ids: ['artifact_${'b' * 32}'])),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('最终成果 · 1 个文件'), findsOneWidget);
      expect(find.textContaining('手机保存未完成'), findsOneWidget);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(cloudExecutionChannel, null);
    },
  );
}

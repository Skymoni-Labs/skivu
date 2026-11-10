import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/cloud_coding_page.dart';
import 'package:ski/cloud_coding_tools.dart';
import 'package:ski/cloud_programs_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <String>[];
  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(cloudExecutionChannel, (call) async {
          calls.add(call.method);
          if (call.method == 'status')
            return {
              'phase': 'ready',
              'migration': {'state': 'not_present'},
            };
          if (call.method == 'resource.policy')
            return {
              'maxParallelJobs': 3,
              'maxAndroidJobs': 0,
              'maxBackgroundRuns': 0,
              'processors': 4,
              'availableMemoryBytes': 1024,
              'automaticParallelJobs': 2,
            };
          if (call.method == 'programs.page')
            return {
              'total': 1,
              'items': [
                {
                  'backend': 'linux',
                  'state': 'stopped',
                  'owner': 'internal-owner',
                  'id': 'opaque-id',
                  'commandPreview': 'python main.py',
                },
              ],
            };
          final args = call.arguments as Map?;
          if (args?['tool'] == 'coding.projects.list')
            return {
              'outcome': 'verified',
              'value': [
                {'name': '我的项目', 'id': 'p1', 'owner': 'test-owner'},
              ],
            };
          return {'outcome': 'verified', 'value': {}};
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(cloudExecutionChannel, null),
  );

  testWidgets('project first screen keeps maintenance actions in its menu', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: CloudCodingPage()));
    await tester.pumpAndSettle();
    expect(find.text('我的项目'), findsNWidgets(2));
    expect(find.text('检查历史数据迁移'), findsNothing);
    await tester.tap(find.byTooltip('项目选项'));
    await tester.pumpAndSettle();
    expect(find.text('检查历史数据迁移'), findsOneWidget);
    expect(calls, isNot(contains('migration.activate')));
    expect(calls, isNot(contains('resource.configure')));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('program records hide internal IDs until details are opened', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: CloudProgramsPage(
          callForOwner: (_) =>
              (_, _) async => {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('已停止'), findsOneWidget);
    expect(find.text('internal-owner'), findsNothing);
    expect(find.textContaining('opaque-id'), findsNothing);
    await tester.tap(find.byTooltip('运行详情'));
    await tester.pumpAndSettle();
    expect(find.text('internal-owner'), findsOneWidget);
    expect(find.text('python main.py'), findsOneWidget);
    expect(calls, ['programs.page']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'resource form preserves custom settings behind advanced options',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: CloudExecutionPolicyPage()),
      );
      await tester.pumpAndSettle();
      expect(find.text('已使用自定义并发'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.text('自定义并发'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        '3',
      );
      expect(calls, ['resource.policy']);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

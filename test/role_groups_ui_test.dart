import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ski/pages.dart';
import 'package:ski/state.dart';

void main() {
  testWidgets(
    'group manager confirms removal, preserves roles, adds with keyboard',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.runAsync(demo.restore);
      addTearDown(demo.dispose);
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      demo.addGroup('实验分组');
      final role = demo.personas.first;
      role.group = '实验分组';
      final ids = demo.conversations.map((c) => c.id).toList();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: CharactersPage(go: (_) {})),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('管理分组'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('删除分组：实验分组'));
      await tester.pumpAndSettle();
      expect(find.textContaining('角色卡和聊天记录会保留'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(role.group, '实验分组');
      await tester.tap(find.byTooltip('删除分组：实验分组'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除分组'));
      await tester.pumpAndSettle();
      expect(role.group, '未分组');
      expect(demo.conversations.map((c) => c.id), ids);
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      await tester.enterText(find.byType(TextField).last, '新分组');
      await tester.pumpAndSettle();
      await tester.tap(find.text('添加分组'));
      await tester.pumpAndSettle();
      expect(demo.groups, contains('新分组'));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

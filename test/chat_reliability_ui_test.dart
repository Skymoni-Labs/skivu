import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ski/main.dart';
import 'package:ski/state.dart';
import 'package:ski/appearance.dart';
import 'package:ski/character_avatar.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('empty chat offers account and BYOK entry', (tester) async {
    demo.conversations
      ..clear()
      ..add(Conversation('空对话', [], personaId: demo.personas.first.id));
    demo.conversation = 0;
    demo.useAccount = false;
    demo.useBeta = false;
    await tester.pumpWidget(const SkiApp());
    await tester.pumpAndSettle();
    expect(find.text('登录中转站'), findsOneWidget);
    expect(find.text('连接自己的 API'), findsOneWidget);
    await tester.tap(find.text('连接自己的 API'));
    await tester.pumpAndSettle();
    expect(find.text('添加模型连接'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('group messages keep author and context notice without retry', (
    tester,
  ) async {
    final roles = demo.personas.take(2).toList();
    final notice = '本轮仅使用最近完整对话，本机历史仍然保留。';
    demo.conversations
      ..clear()
      ..add(
        Conversation('群聊', [
          Message(false, '第一位的回复')..authorId = roles.first.id,
          Message(false, '第二位的回复')
            ..authorId = roles.last.id
            ..contextNotice = notice,
        ], personaId: roles.first.id),
      );
    demo.conversation = 0;
    appearance.set('showRole', true);
    appearance.set('avatars', true);
    await tester.pumpWidget(const SkiApp());
    await tester.pumpAndSettle();
    expect(find.text(roles.last.name), findsOneWidget);
    expect(find.text(notice), findsOneWidget);
    expect(find.text('重试'), findsNothing);
    expect(
      tester
          .widgetList<CharacterAvatar>(find.byType(CharacterAvatar))
          .any((w) => w.persona.id == roles.last.id),
      isTrue,
    );
    await tester.pumpWidget(const SizedBox());
  });
}

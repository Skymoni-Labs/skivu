import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ski/legacy_social_migration.dart';
import 'package:ski/native_social_page.dart';
import 'package:ski/native_social_chat.dart';
import 'package:ski/state.dart';
import 'package:ski/ui_plugins.dart';
import 'real_chat_store_test.dart' show MemoryChats;

void main() {
  late DemoStore store;
  setUp(() {
    // These exercise navigation after local recovery. The separate migration
    // suite owns the native extraction channel and its retry/timeout lifecycle.
    SharedPreferences.setMockInitialValues({
      LegacySocialMigration.doneKey: true,
      LegacySocialMigration.optionsDoneKey: true,
    });
    uiPlugins.mode = ChatUiMode.wechat;
    uiPlugins.tab = 0;
    uiPlugins.conversationVisible = false;
    uiPlugins.homeRevision++;
    store = DemoStore(storage: MemoryChats());
    store.conversations
      ..clear()
      ..add(
        Conversation('独立会话', [
          Message(true, '旧消息'),
        ], personaId: store.personas.first.id)..titleEdited = true,
      );
    store.conversation = 0;
  });
  tearDown(() => store.dispose());
  Widget surface({bool blocked = false}) => MaterialApp(
    home: Scaffold(
      body: NativeSocialPage(
        store: store,
        go: (_) {},
        openNavigation: () {},
        openWorkspace: () {},
        backBlocked: () => blocked,
      ),
    ),
  );

  Future<void> openChat(WidgetTester tester) async {
    await tester.tap(find.text('独立会话'));
    await tester.pumpAndSettle();
    expect(find.byType(NativeSocialChat), findsOneWidget);
  }

  testWidgets('horizontal cards follow a drag and preserve ordered root tabs', (
    tester,
  ) async {
    await tester.pumpWidget(surface());
    await tester.pumpAndSettle();
    final pager = find.byKey(const ValueKey('native-social-pager'));
    final gesture = await tester.startGesture(tester.getCenter(pager));
    // The first move crosses touch slop and wins the horizontal gesture arena;
    // the next move is the actual in-progress card position being inspected.
    await gesture.moveBy(const Offset(-40, 0));
    await tester.pump(const Duration(milliseconds: 20));
    await gesture.moveBy(const Offset(-160, 0));
    await tester.pump(const Duration(milliseconds: 20));
    final controller = tester.widget<PageView>(pager).controller!;
    expect(controller.page, inExclusiveRange(0, 1));
    await gesture.moveBy(const Offset(-450, 0));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(uiPlugins.tab, 1);
    await tester.tap(find.text('发现').last);
    await tester.pumpAndSettle();
    expect(uiPlugins.tab, 2);
    expect(find.text('朋友圈'), findsOneWidget);
    await tester.tap(find.text('我').last);
    await tester.pumpAndSettle();
    expect(uiPlugins.tab, 3);
    expect(find.text('服务'), findsOneWidget);
  });

  testWidgets(
    'internal system back returns through info without losing chat state',
    (tester) async {
      await tester.pumpWidget(surface());
      await tester.pumpAndSettle();
      await openChat(tester);
      final before = tester.state(find.byType(NativeSocialChat));
      await tester.enterText(
        find.byKey(const ValueKey('social-chat-input')),
        '未发送草稿',
      );
      await tester.tap(find.byTooltip('聊天信息'));
      await tester.pumpAndSettle();
      expect(find.text('查找聊天记录'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(NativeSocialChat)), same(before));
      expect(find.text('未发送草稿'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('native-social-pager')), findsOneWidget);
      expect(store.conversations.single.draft, '未发送草稿');
    },
  );

  testWidgets(
    'QQ chat right swipe returns internally without changing conversation',
    (tester) async {
      uiPlugins.mode = ChatUiMode.qq;
      await tester.pumpWidget(surface());
      await tester.pumpAndSettle();
      await openChat(tester);
      final id = store.conversations.single.id;
      await tester.dragFrom(const Offset(120, 220), const Offset(200, 0));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('native-social-pager')), findsOneWidget);
      expect(store.conversations[store.conversation].id, id);
      expect(store.conversations.single.messages.length, 1);
    },
  );

  testWidgets('parent drawer can block inner back without resetting the chat', (
    tester,
  ) async {
    await tester.pumpWidget(surface(blocked: true));
    await tester.pumpAndSettle();
    await openChat(tester);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('social-chat-input')), findsOneWidget);
    expect(uiPlugins.conversationVisible, true);
  });

  testWidgets(
    'horizontal drag inside the composer preserves the chat and draft',
    (tester) async {
      await tester.pumpWidget(surface());
      await tester.pumpAndSettle();
      await openChat(tester);
      final input = find.byKey(const ValueKey('social-chat-input'));
      const draft = '保留这段未发送草稿，输入框内左右拖动不能返回。';
      await tester.enterText(input, draft);
      await tester.pumpAndSettle();
      final before = tester.state(find.byType(NativeSocialChat));
      final bounds = tester.getRect(input);
      await tester.dragFrom(
        Offset(bounds.left + 20, bounds.center.dy),
        Offset((bounds.width - 40).clamp(100, 200).toDouble(), 0),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('native-social-pager')), findsNothing);
      expect(find.byKey(const ValueKey('social-chat-input')), findsOneWidget);
      expect(tester.state(find.byType(NativeSocialChat)), same(before));
      expect(tester.widget<TextField>(input).controller!.text, draft);
      expect(store.conversations.single.draft, draft);
      expect(uiPlugins.conversationVisible, true);
    },
  );
  testWidgets('latest visible attachment controls inbox order and time', (
    tester,
  ) async {
    final chat = store.conversations.single;
    chat.messages.clear();
    chat.interactions.add({
      'id': 'qa-file',
      'kind': 'file',
      'created': '2026-10-24T20:00:00',
      'user': true,
      'payload': {'name': 'qa.txt', 'data': 'data:text/plain;base64,cWE='},
    });
    store.conversations.add(
      Conversation('另一段会话', [
        Message(true, '另一段较旧消息', created: DateTime(2026, 10, 24, 13)),
      ], personaId: store.personas.first.id)..titleEdited = true,
    );
    await tester.pumpWidget(surface());
    await tester.pumpAndSettle();
    expect(find.text('20:00'), findsOneWidget);
    expect(find.text('[文件]'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('独立会话')).dy,
      lessThan(tester.getTopLeft(find.text('另一段会话')).dy),
    );
    chat.hiddenInteractions.add('qa-file');
    store.changed();
    await tester.pumpAndSettle();
    expect(find.text('20:00'), findsNothing);
    expect(
      tester.getTopLeft(find.text('另一段会话')).dy,
      lessThan(tester.getTopLeft(find.text('独立会话')).dy),
    );
  });

  testWidgets('QQ add page retains all original actions', (tester) async {
    uiPlugins.mode = ChatUiMode.qq;
    await tester.pumpWidget(surface());
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('添加对话'));
    await tester.pumpAndSettle();
    for (final title in ['新建对话', '角色管理', '我的资料与头像', '回到原版']) {
      expect(find.text(title), findsOneWidget);
    }
    await tester.tap(find.text('新建对话'));
    await tester.pumpAndSettle();
    expect(find.text('选择角色'), findsOneWidget);
    expect(store.conversations, hasLength(1));
  });

  testWidgets('empty QQ groups retain the create group flow', (tester) async {
    uiPlugins.mode = ChatUiMode.qq;
    uiPlugins.tab = 2;
    await tester.pumpWidget(surface());
    await tester.pumpAndSettle();
    await tester.tap(find.text('群聊').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('＋ 发起群聊'));
    await tester.pumpAndSettle();
    expect(find.text('群名称'), findsOneWidget);
    expect(find.text('创建群聊'), findsOneWidget);
    expect(store.conversations, hasLength(1));
  });
}

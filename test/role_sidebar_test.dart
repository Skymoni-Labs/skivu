import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/state.dart';
import 'package:ski/main.dart' show SideNavigation;
import 'package:ski/role_conversation_tree.dart';
import 'package:ski/character_avatar.dart';
import 'wallpaper_test.dart' show imageBytes;
import 'real_chat_store_test.dart' show MemoryChats;

Future<DemoStore> fixture() async {
  final store = DemoStore(storage: MemoryChats());
  await store.restore();
  store.personas[0].name = 'ski';
  store.personas[1].name = '许知夏';
  store.newChat(personaId: store.personas[0].id);
  store.renameChat(store.conversations.first.id, '日常闲聊');
  store.newChat(personaId: store.personas[0].id);
  store.renameChat(store.conversations.first.id, '一起做计划');
  store.newChat(personaId: store.personas[1].id);
  store.renameChat(store.conversations.first.id, '旅行计划');
  return store;
}

Widget host(DemoStore store, {String query = '', VoidCallback? open}) =>
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SizedBox(
            width: 270,
            child: RoleConversationTree(
              store: store,
              query: query,
              openChat: open ?? () {},
            ),
          ),
        ),
      ),
    );

void main() {
  testWidgets('sidebar edge drags keep glass outside Android stretch layers', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android, useMaterial3: true),
        home: Scaffold(
          body: SizedBox(
            width: 262,
            child: SideNavigation(route: '/chat', go: (_) {}, close: () {}),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final list = find.byKey(const ValueKey('sidebar-scroll'));
    // Stretch isolates the live-backdrop lens and makes it sample black on
    // Impeller. Checking the layer-producing wrapper catches the regression
    // even though widget tests cannot run Android's shader-filter renderer.
    expect(
      find.descendant(
        of: list,
        matching: find.byType(StretchingOverscrollIndicator),
      ),
      findsNothing,
    );
    final scrollable = tester.state<ScrollableState>(
      find.descendant(of: list, matching: find.byType(Scrollable)).first,
    );
    final pull = await tester.startGesture(tester.getCenter(list));
    await pull.moveBy(const Offset(0, 160));
    await tester.pump(const Duration(milliseconds: 100));
    expect(scrollable.position.pixels, 0);
    await pull.up();
    await tester.pumpAndSettle();
    await tester.drag(list, const Offset(0, -1800));
    await tester.pumpAndSettle();
    expect(scrollable.position.pixels, greaterThan(0));
    expect(find.text('设置'), findsOneWidget);
    await tester.drag(list, const Offset(0, 1800));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('新建对话'));
    await tester.pumpAndSettle();
    expect(find.text('选择对话角色'), findsOneWidget);
    Navigator.of(tester.element(find.text('选择对话角色'))).pop();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'role folder menu confirms deletion with its conversation count',
    (tester) async {
      final store = await fixture();
      final role = store.personas.first;
      await tester.pumpWidget(host(store));
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byKey(ValueKey('role-folder-${role.id}'))).height,
        48,
      );
      await tester.tap(find.byKey(ValueKey('role-menu-${role.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除角色'));
      await tester.pumpAndSettle();
      expect(find.textContaining('2 段对话和聊天记录'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(store.personas, contains(role));
      await tester.tap(find.byKey(ValueKey('role-menu-${role.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除角色'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除角色及对话'));
      await tester.pumpAndSettle();
      expect(store.personas, isNot(contains(role)));
      expect(store.conversationsFor(role.id), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      store.dispose();
    },
  );
  testWidgets(
    'one folder per role, counts, inside creation and title search retain role ownership',
    (tester) async {
      final store = await fixture();
      final a = store.personas[0], b = store.personas[1];
      var opened = 0;
      await tester.pumpWidget(host(store, open: () => opened++));
      await tester.pumpAndSettle();
      expect(find.text('日常对话'), findsNothing);
      final avatar = find.byKey(ValueKey('sidebar-role-avatar-${a.id}'));
      expect(tester.widget<CharacterAvatar>(avatar).persona, same(a));
      expect(find.byIcon(Icons.folder_open_outlined), findsNothing);
      expect(find.byIcon(Icons.folder_outlined), findsNothing);
      a.avatar = imageBytes;
      store.changed();
      await tester.pumpAndSettle();
      final picture = find.descendant(of: avatar, matching: find.byType(Image));
      expect(tester.widget<Image>(picture).image, isA<MemoryImage>());
      expect(
        (tester.widget<Image>(picture).image as MemoryImage).bytes,
        imageBytes,
      );
      expect(find.text('日常'), findsNothing);
      expect(find.byKey(ValueKey('role-count-${a.id}')), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(ValueKey('role-count-${a.id}'))).data,
        '2',
      );
      await tester.tap(find.byKey(ValueKey('role-new-chat-${a.id}')));
      await tester.pumpAndSettle();
      expect(opened, 1);
      expect(store.role.id, a.id);
      expect(store.conversationsFor(a.id), hasLength(3));
      store.toggleFolder(a.id);
      await tester.pumpWidget(host(store, query: '计划'));
      await tester.pumpAndSettle();
      expect(find.text('ski'), findsOneWidget);
      expect(find.text('许知夏'), findsOneWidget);
      expect(find.text('一起做计划'), findsOneWidget);
      expect(find.text('旅行计划'), findsOneWidget);
      expect(find.text('日常闲聊'), findsNothing);
      expect(store.folderExpanded(a.id), isFalse);
      await tester.pumpWidget(host(store, query: 'SKI'));
      await tester.pumpAndSettle();
      expect(find.text('日常闲聊'), findsOneWidget);
      expect(find.text('许知夏'), findsNothing);
      await tester.pumpWidget(host(store));
      await tester.pumpAndSettle();
      expect(find.text('日常闲聊'), findsNothing);
      expect(store.conversationsFor(b.id), hasLength(1));
      await tester.pumpWidget(const SizedBox());
      store.dispose();
    },
  );

  testWidgets(
    'conversation menus rename, pin and require explicit deletion confirmation',
    (tester) async {
      final store = await fixture();
      final role = store.personas.first;
      final older = store.conversationsFor(role.id).last;
      await tester.pumpWidget(host(store));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('chat-menu-${older.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('重命名'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('rename-chat-field')),
        '新的日常标题',
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(older.title, '新的日常标题');
      await tester.tap(find.byKey(ValueKey('chat-menu-${older.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('置顶'));
      await tester.pumpAndSettle();
      expect(store.conversationsFor(role.id).first.id, older.id);
      await tester.tap(find.byKey(ValueKey('chat-menu-${older.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(find.text('删除对话？'), findsOneWidget);
      expect(store.conversationsFor(role.id), hasLength(2));
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(store.conversationsFor(role.id), hasLength(2));
      await tester.tap(find.byKey(ValueKey('chat-menu-${older.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(store.conversationsFor(role.id), hasLength(1));
      expect(find.text('新的日常标题'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      store.dispose();
    },
  );

  testWidgets(
    'global new chat asks for a role first and sidebar fits narrow keyboard layouts',
    (tester) async {
      tester.view.physicalSize = const Size(320, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      demo.stop();
      demo.conversations
        ..clear()
        ..add(Conversation('保留的对话', [], personaId: demo.personas.first.id));
      demo.conversation = 0;
      final original = demo.conversations.length;
      var destination = '';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(
                size: Size(320, 740),
                textScaler: TextScaler.linear(1.2),
              ),
              child: SizedBox(
                width: 262,
                child: SideNavigation(
                  route: '/chat',
                  go: (v) => destination = v,
                  close: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('角色与陪伴'), findsNothing);
      expect(tester.getTopLeft(find.text('Skivu').first).dy, lessThan(32));
      final columnX = tester.getTopLeft(find.text('Skivu').first).dx;
      final newChatLabel = find.descendant(
        of: find.byTooltip('新建对话'),
        matching: find.text('新建对话'),
      );
      for (final item in [
        newChatLabel,
        find.text('搜索角色或对话'),
        find.text('角色'),
        find.text('插件市场'),
      ]) {
        expect(tester.getTopLeft(item).dx, closeTo(columnX, .01));
      }
      await tester.tap(find.byTooltip('新建对话'));
      await tester.pumpAndSettle();
      expect(find.text('选择对话角色'), findsOneWidget);
      expect(demo.conversations, hasLength(original));
      final target = demo.personas[1];
      await tester.tap(find.byKey(ValueKey('pick-chat-role-${target.id}')));
      await tester.pumpAndSettle();
      expect(destination, '/chat');
      expect(demo.role.id, target.id);
      expect(demo.conversations, hasLength(original + 1));
      // The full header/list can scroll, while the bottom settings entry remains usable.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(
                size: Size(320, 740),
                textScaler: TextScaler.linear(1.2),
              ),
              child: SizedBox(
                width: 262,
                height: 350,
                child: SideNavigation(route: '/chat', go: (_) {}, close: () {}),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('设置'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

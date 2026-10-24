import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ski/native_social_details.dart';
import 'package:ski/social_settings.dart';
import 'package:ski/state.dart';
import 'package:ski/ui_plugins.dart';
import 'real_chat_store_test.dart' show MemoryChats;

void main() {
  late DemoStore store;
  late SocialConfig savedConfig;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    savedConfig = socialSettings.value;
    socialSettings.value = const SocialConfig();
    store = DemoStore(storage: MemoryChats());
    store.personas
      ..clear()
      ..addAll([
        for (var i = 0; i < 9; i++)
          Persona(
            '角色$i',
            '简介$i',
            '提示$i',
            '默认',
            Colors.green,
            Icons.face_outlined,
            id: 'role-$i',
          ),
      ]);
    store.conversations.clear();
  });
  tearDown(() {
    store.dispose();
    socialSettings.value = savedConfig;
  });
  Widget surface(Widget child) => MaterialApp(home: Scaffold(body: child));
  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    // Focusing a text field can finish changing the keyboard/scroll viewport
    // during the first settle. Re-evaluate visibility in that final layout.
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<void> openForm(
    WidgetTester tester, {
    ChatUiMode mode = ChatUiMode.wechat,
    Conversation? existing,
    List<String> initialMembers = const [],
    bool channel = false,
    required ValueChanged<NativeSocialGroupValue?> result,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async => result(
                await showNativeSocialGroupForm(
                  context,
                  mode: mode,
                  store: store,
                  existingChat: existing,
                  initialMembers: initialMembers,
                  channel: channel,
                ),
              ),
              child: const Text('打开表单'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开表单'));
    await tester.pumpAndSettle();
  }

  const save = ValueKey('native-social-group-save');

  testWidgets(
    'contact details retain all entry points and narrow-screen scrolling',
    (tester) async {
      tester.view.physicalSize = const Size(280, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final calls = <String>[];
      final role = store.personas.first;
      final before = role.toJson();
      await tester.pumpWidget(
        surface(
          NativeSocialContactDetails(
            mode: ChatUiMode.wechat,
            store: store,
            role: role,
            onBack: () => calls.add('back'),
            onRename: () => calls.add('rename'),
            onEditRole: () => calls.add('edit'),
            onPrivacy: () => calls.add('privacy'),
            onMoments: () => calls.add('moments'),
            onMoreInfo: () => calls.add('more'),
            onChat: () => calls.add('chat'),
            onCall: () => calls.add('call'),
          ),
        ),
      );
      for (final entry in {
        '备注和标签': 'rename',
        '编辑角色卡': 'edit',
        '朋友权限': 'privacy',
        '朋友圈': 'moments',
        '更多信息': 'more',
        '发消息': 'chat',
        '音视频通话': 'call',
      }.entries) {
        await tapVisible(tester, find.text(entry.key));
        expect(calls.last, entry.value);
      }
      // The actual call preview owns the disabled video control; the original
      // contact page itself only had this compact call action.
      expect(find.text('音视频通话'), findsOneWidget);
      expect(
        tester
            .getSize(
              find
                  .ancestor(
                    of: find.text('发消息'),
                    matching: find.byType(InkWell),
                  )
                  .first,
            )
            .width,
        184,
      );
      expect(role.toJson(), before);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'chat settings expose actual member identities and callback-only toggles',
    (tester) async {
      final chat = Conversation('测试群', [], personaId: 'role-0')
        ..groupMembers = ['role-0', 'role-1', 'deleted'];
      Persona? selected;
      var user = 0, add = 0;
      String? key;
      bool? value;
      await tester.pumpWidget(
        surface(
          NativeSocialChatInfo(
            mode: ChatUiMode.wechat,
            store: store,
            chat: chat,
            onBack: () {},
            onRole: (role) => selected = role,
            onUser: () => user++,
            onAddMembers: () => add++,
            onSearch: () {},
            onToggle: (k, v) {
              key = k;
              value = v;
            },
            onBackground: () {},
            onBubbles: () {},
            onClear: () {},
            onReport: () {},
          ),
        ),
      );
      await tester.tap(find.text('角色1'));
      expect(selected, same(store.personas[1]));
      await tester.tap(find.text('我'));
      expect(user, 1);
      await tester.tap(find.bySemanticsLabel('添加聊天成员'));
      expect(add, 1);
      await tapVisible(
        tester,
        find.byKey(const ValueKey('native-social-toggle-confirmBeforeReply')),
      );
      expect(key, 'confirmBeforeReply');
      expect(value, isTrue);
      expect(chat.confirmBeforeReply, isFalse);
      expect(find.text('置顶聊天'), findsOneWidget);
      await tapVisible(tester, find.text('投诉'));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'QQ settings retain QQ labels and a working group creation entry',
    (tester) async {
      var create = 0;
      await tester.pumpWidget(
        surface(
          NativeSocialChatInfo(
            mode: ChatUiMode.qq,
            store: store,
            chat: Conversation('单聊', [], personaId: 'role-0'),
            onBack: () {},
            onRole: (_) {},
            onUser: () {},
            onAddMembers: () => create++,
            onSearch: () {},
            onToggle: (_, _) {},
            onBackground: () {},
            onBubbles: () {},
            onClear: () {},
            onReport: () {},
          ),
        ),
      );
      expect(find.text('聊天设置'), findsOneWidget);
      final header = find.byKey(const ValueKey('native-social-details-header'));
      expect(
        tester.getSize(header).width,
        tester.view.physicalSize.width / tester.view.devicePixelRatio,
      );
      expect(tester.getSize(header).height, 56);
      expect(tester.getTopLeft(find.bySemanticsLabel('返回')).dx, lessThan(20));
      await tapVisible(tester, find.text('发起群聊'));
      expect(create, 1);
      expect(find.text('设为置顶'), findsOneWidget);
      expect(find.text('特别关心'), findsOneWidget);
      expect(find.text('投诉'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('group list excludes channels and counts the current user', (
    tester,
  ) async {
    final group = Conversation('保留群聊', [], personaId: 'role-0')
      ..groupMembers = ['role-0', 'role-1'];
    store.conversations.addAll([
      Conversation('单人会话', [], personaId: 'role-0'),
      group,
      Conversation('频道应隐藏', [], personaId: 'role-0')
        ..groupMembers = ['role-0', 'role-1']
        ..groupKind = 'channel',
    ]);
    Conversation? opened;
    var created = 0;
    await tester.pumpWidget(
      surface(
        NativeSocialGroupList(
          mode: ChatUiMode.wechat,
          store: store,
          onBack: () {},
          onCreate: () => created++,
          onOpen: (value) => opened = value,
        ),
      ),
    );
    expect(find.text('3 位成员'), findsOneWidget);
    expect(find.text('频道应隐藏'), findsNothing);
    expect(find.text('单人会话'), findsNothing);
    await tester.tap(find.text('保留群聊'));
    expect(opened, same(group));
    await tester.tap(find.text('发起群聊'));
    expect(created, 1);
  });

  testWidgets(
    'new group merges valid defaults, keeps display order, and returns without mutation',
    (tester) async {
      socialSettings.value = const SocialConfig(
        groupMembers: ['role-1', 'role-1', 'deleted'],
        groupRule: GroupReplyRule.roundRobin,
        groupMaxReplies: 3,
      );
      NativeSocialGroupValue? result;
      await openForm(
        tester,
        initialMembers: ['role-2', 'role-0', 'role-2'],
        result: (value) => result = value,
      );
      await tester.enterText(
        find.byKey(const ValueKey('native-social-group-title')),
        '  我的群  ',
      );
      await tapVisible(tester, find.byKey(save));
      expect(result?.title, '我的群');
      expect(result?.members, ['role-0', 'role-1', 'role-2']);
      expect(result?.rule, 'roundRobin');
      expect(result?.maxReplies, 3);
      expect(result?.kind, 'group');
      expect(store.conversations, isEmpty);
    },
  );

  testWidgets(
    'editing preserves channel config and does not introduce global default members',
    (tester) async {
      socialSettings.value = const SocialConfig(groupMembers: ['role-8']);
      final chat = Conversation('现有频道', [])
        ..groupMembers = ['role-3', 'role-1', 'deleted', 'role-3']
        ..groupKind = 'channel'
        ..groupRule = 'mentions'
        ..groupMaxReplies = 5;
      NativeSocialGroupValue? result;
      await openForm(
        tester,
        mode: ChatUiMode.qq,
        existing: chat,
        initialMembers: ['role-7'],
        result: (value) => result = value,
      );
      expect(find.text('频道成员与设置'), findsOneWidget);
      await tapVisible(tester, find.byKey(save));
      expect(result?.title, '现有频道');
      expect(result?.members, ['role-1', 'role-3']);
      expect(result?.kind, 'channel');
      expect(result?.rule, 'mentions');
      expect(result?.maxReplies, 5);
      expect(chat.groupMembers, ['role-3', 'role-1', 'deleted', 'role-3']);
    },
  );

  testWidgets(
    'form enforces 2–8 members, stays scrollable with a keyboard, and recovers after validation',
    (tester) async {
      tester.view.physicalSize = const Size(280, 580);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      NativeSocialGroupValue? result;
      await openForm(
        tester,
        initialMembers: ['role-0'],
        result: (value) => result = value,
      );
      await tapVisible(tester, find.byKey(save));
      expect(find.text('请填写群名称并选择 2—8 位现有角色。'), findsOneWidget);
      expect(result, isNull);
      for (var i = 1; i <= 8; i++) {
        await tapVisible(
          tester,
          find.byKey(ValueKey('native-social-group-member-role-$i')),
        );
      }
      expect(find.text('最多选择 8 位角色。'), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const ValueKey('native-social-group-title')),
      );
      await tester.tap(find.byKey(const ValueKey('native-social-group-title')));
      tester.view.viewInsets = const FakeViewPadding(bottom: 240);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('native-social-group-title')),
        '窄屏群',
      );
      await tapVisible(tester, find.byKey(save));
      expect(result?.members.length, 8);
      expect(result?.members, isNot(contains('role-8')));
      expect(tester.takeException(), isNull);
    },
  );
}

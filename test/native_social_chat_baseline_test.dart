import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ski/appearance.dart';
import 'package:ski/chat_api.dart';
import 'package:ski/chat_bubble_surface.dart';
import 'package:ski/companion_library.dart';
import 'package:ski/glass_preferences.dart';
import 'package:ski/model_settings.dart';
import 'package:ski/native_social_chat.dart';
import 'package:ski/native_social_chat_widgets.dart';
import 'package:ski/native_social_local_options.dart';
import 'package:ski/state.dart';
import 'package:ski/ui_plugins.dart';
import 'package:ski/virtual_wallet.dart';
import 'real_chat_store_test.dart' show MemoryChats;

void main() {
  late DemoStore store;
  late ModelSettings models;
  late Map<String, dynamic> oldAppearance;
  var requests = 0;
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await virtualWallet.restore();
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    oldAppearance = appearance.values;
    requests = 0;
    models = ModelSettings();
    store = DemoStore(
      settings: models,
      storage: MemoryChats(),
      api: ChatApi(
        clientFactory: () => MockClient((_) async {
          requests++;
          throw StateError('No real request permitted');
        }),
      ),
    );
    store.conversations
      ..clear()
      ..add(Conversation('原对话标题', [], personaId: store.personas.first.id));
    store.conversation = 0;
  });
  tearDown(() {
    expect(requests, 0);
    store.dispose();
    models.dispose();
    for (final e in oldAppearance.entries) appearance.set(e.key, e.value);
    glassPreferences.setBubbleBlur(user: true, value: 6);
    nativeSocialLocalOptions.fontSize = 16;
  });
  Widget surface(ChatUiMode mode) => MaterialApp(
    home: Scaffold(
      body: NativeSocialChat(
        mode: mode,
        store: store,
        go: (_) {},
        onBack: () {},
        onInfo: () {},
      ),
    ),
  );
  void phone(WidgetTester tester, [Size size = const Size(430, 900)]) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  testWidgets(
    'chat headers fill 360dp and keep back at left12 with top safe area',
    (tester) async {
      phone(tester, const Size(360, 800));
      tester.view.padding = const FakeViewPadding(top: 24);
      for (final mode in [ChatUiMode.wechat, ChatUiMode.qq]) {
        await tester.pumpWidget(surface(mode));
        await tester.pumpAndSettle();
        final rect = tester.getRect(
          find.byKey(const ValueKey('social-chat-header')),
        );
        expect(rect.left, 0);
        expect(rect.width, 360);
        expect(rect.height, mode == ChatUiMode.wechat ? 76 : 80);
        expect(tester.getRect(find.byTooltip('返回')).left, 12);
        expect(tester.getRect(find.byTooltip('聊天信息')).right, 348);
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    '0.2.34 QQ geometry white-blue bubbles and original controls match CSS dimensions',
    (tester) async {
      phone(tester);
      store.messages.addAll([Message(false, '白色回复'), Message(true, '蓝色消息')]);
      await tester.pumpWidget(surface(ChatUiMode.qq));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SocialChatSurface>(find.byType(SocialChatSurface).first)
            .custom,
        isFalse,
      );
      final user = tester.widget<Container>(
        find.byKey(const ValueKey('social-native-surface-user')),
      );
      expect((user.decoration as BoxDecoration).color, const Color(0xff009dff));
      expect(
        (user.decoration as BoxDecoration).borderRadius,
        BorderRadius.circular(9),
      );
      expect(
        user.padding,
        const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      );
      expect(
        tester
            .getRect(find.byKey(const ValueKey('social-native-surface-user')))
            .width,
        lessThan(200),
      );
      expect(find.byType(ChatBubbleSurface), findsNothing);
      expect(
        tester.getRect(find.byKey(const ValueKey('social-chat-header'))).height,
        56,
      );
      expect(
        tester.getRect(find.byKey(const ValueKey('social-chat-input'))).height,
        closeTo(38, .2),
      );
      expect(
        tester.getRect(find.byKey(const ValueKey('social-send'))).size,
        const Size(54, 35),
      );
      expect(find.text('当前对话'), findsOneWidget);
      final style = DefaultTextStyle.of(
        tester.element(find.text('蓝色消息')),
      ).style;
      expect(style.fontSize, 16);
      expect(style.height, 1.5);
      expect(style.color, Colors.white);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'explicit colors and nondefault blur retain shared appearance without rewriting it',
    (tester) async {
      phone(tester);
      store.messages.addAll([Message(false, '回复'), Message(true, '消息')]);
      appearance.set('customMessageColors', true);
      appearance.set('userColor', 0xffaa3355);
      await tester.pumpWidget(surface(ChatUiMode.qq));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SocialChatSurface>(find.byType(SocialChatSurface).last)
            .custom,
        isTrue,
      );
      expect(find.byType(ChatBubbleSurface), findsNWidgets(2));
      expect(appearance.color('userColor'), const Color(0xffaa3355));
      await tester.pumpWidget(const SizedBox());
      for (final e in oldAppearance.entries) appearance.set(e.key, e.value);
      glassPreferences.setBubbleBlur(user: true, value: 7);
      await tester.pumpWidget(surface(ChatUiMode.qq));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SocialChatSurface>(find.byType(SocialChatSurface).first)
            .custom,
        isTrue,
      );
      await tester.pumpWidget(const SizedBox());
      glassPreferences.setBubbleBlur(user: true, value: 6);
      await tester.pumpWidget(surface(ChatUiMode.wechat));
      await tester.pumpAndSettle();
      expect(
        (tester
                    .widget<Container>(
                      find.byKey(const ValueKey('social-native-surface-user')),
                    )
                    .decoration
                as BoxDecoration)
            .color,
        const Color(0xff95ec69),
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'inline emoji inserts at selection and grouped stickers use the original queued store',
    (tester) async {
      phone(tester);
      store.conversations.first.confirmBeforeReply = true;
      store.stickerGroups.add(StickerGroup('native-sticker-group', '我的分组'));
      store.stickers.add(
        StickerAsset(
          id: 'native-sticker-item',
          groupId: 'native-sticker-group',
          name: '测试贴纸',
          data:
              'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAGUlEQVR4nGN0aDjCQApgIkn1qIZRDUNKAwDVAAGkxqTHVQAAAABJRU5ErkJggg==',
        ),
      );
      await tester.pumpWidget(surface(ChatUiMode.qq));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('social-chat-input')),
        '前后',
      );
      await tester.pump();
      tester
          .widget<TextField>(find.byKey(const ValueKey('social-chat-input')))
          .controller!
          .selection = const TextSelection.collapsed(
        offset: 1,
      );
      await tester.tap(find.byTooltip('表情包'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('social-inline-emoji')), findsOneWidget);
      await tester.tap(find.text('😊'));
      await tester.pumpAndSettle();
      expect(store.conversations.first.draft, '前😊后');
      await tester.ensureVisible(find.text('我的分组'));
      await tester.tap(find.text('我的分组'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('测试贴纸'));
      await tester.tap(find.text('测试贴纸'));
      await tester.pumpAndSettle();
      expect(store.messages.single.kind, 'sticker');
      expect(store.messages.single.stickerId, 'native-sticker-item');
      expect(store.messages.single.status, 'queued');
      expect(find.byType(ChatBubbleSurface), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'local font only changes social messages and inline panels fit keyboard-resized constraints',
    (tester) async {
      phone(tester, const Size(320, 700));
      store.messages.add(Message(true, '单独调整的消息字体'));
      await tester.pumpWidget(surface(ChatUiMode.qq));
      await tester.pumpAndSettle();
      nativeSocialLocalOptions.fontSize = 18;
      nativeSocialLocalOptions.notifyListeners();
      await tester.pumpAndSettle();
      expect(
        DefaultTextStyle.of(
          tester.element(find.text('单独调整的消息字体')),
        ).style.fontSize,
        18,
      );
      expect(appearance.values, oldAppearance);
      tester.view.viewInsets = const FakeViewPadding(bottom: 330);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('更多功能'));
      await tester.pumpAndSettle();
      expect(
        tester
            .getRect(find.byKey(const ValueKey('social-chat-composer')))
            .bottom,
        closeTo(370, .5),
      );
      expect(tester.takeException(), isNull);
      tester.view.viewInsets = FakeViewPadding.zero;
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'WeChat inline plus and smile preserve paged tools, voice mode and date separators',
    (tester) async {
      phone(tester);
      store.messages.add(Message(true, '恢复的微信消息', created: DateTime.now()));
      await tester.pumpWidget(surface(ChatUiMode.wechat));
      await tester.pumpAndSettle();
      expect(find.textContaining('今天 '), findsOneWidget);
      expect(find.text('当前对话'), findsNothing);
      await tester.tap(find.byTooltip('更多功能'));
      await tester.pumpAndSettle();
      for (final text in ['相册', '拍摄', '视频通话', '位置', '红包', '礼物', '转账', '语音输入'])
        expect(find.text(text), findsOneWidget);
      await tester.tap(find.byTooltip('更多功能第 2 页'));
      await tester.pumpAndSettle();
      for (final text in ['收藏', '个人名片', '文件', '音乐', '描述照片'])
        expect(find.text(text), findsOneWidget);
      await tester.tap(find.byTooltip('表情包'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('social-inline-emoji')), findsOneWidget);
      await tester.tap(find.byTooltip('语音识别'));
      await tester.pumpAndSettle();
      expect(find.text('按住 说话'), findsOneWidget);
      expect(find.byKey(const ValueKey('social-inline-emoji')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'WeChat redpacket entry keeps its two-row full-page submenu before the shared form',
    (tester) async {
      phone(tester);
      await tester.pumpWidget(surface(ChatUiMode.wechat));
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byKey(const ValueKey('social-chat-header'))).height,
        52,
      );
      await tester.tap(find.byTooltip('更多功能'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('红包'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ListTile, '红包'), findsOneWidget);
      expect(find.widgetWithText(ListTile, '拜年红包'), findsOneWidget);
      expect(tester.widget<AppBar>(find.byType(AppBar)).toolbarHeight, 54);
      await tester.tap(find.text('拜年红包'));
      await tester.pumpAndSettle();
      expect(find.text('发红包'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('social-finance-amount')),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 300));
      expect(store.messages, isEmpty);
      expect(store.conversations.first.interactions, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

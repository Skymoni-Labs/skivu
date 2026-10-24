import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ski/appearance.dart';
import 'package:ski/chat_api.dart';
import 'package:ski/native_social_chat_widgets.dart';
import 'package:ski/native_social_media_preview.dart';
import 'package:ski/native_social_portrait.dart';
import 'package:ski/model_settings.dart';
import 'package:ski/native_social_chat.dart';
import 'package:ski/state.dart';
import 'package:ski/ui_plugins.dart';
import 'package:ski/virtual_wallet.dart';

import 'real_chat_store_test.dart' show MemoryChats;

class _PresenterStore extends DemoStore {
  _PresenterStore({required ModelSettings settings, required ChatApi api})
    : super(settings: settings, api: api, storage: MemoryChats());
  final sendModes = <bool?>[], confirmModes = <bool?>[];
  @override
  bool send(
    String input, {
    bool? streamingOverride,
    String kind = 'text',
    String? stickerId,
    bool immediate = false,
    String? imageData,
    bool described = false,
  }) {
    sendModes.add(streamingOverride);
    return super.send(
      input,
      streamingOverride: streamingOverride,
      kind: kind,
      stickerId: stickerId,
      immediate: immediate,
      imageData: imageData,
      described: described,
    );
  }

  @override
  bool confirmPending({bool? streamingOverride}) {
    confirmModes.add(streamingOverride);
    return super.confirmPending(streamingOverride: streamingOverride);
  }
}

void main() {
  late DemoStore store;
  late ModelSettings models;
  int requests = 0;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    // Initialize the singleton's persistence queue outside any widget test's
    // fake clock so later ledger writes cannot inherit an expired test zone.
    await virtualWallet.restore();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    requests = 0;
    models = ModelSettings();
    store = _PresenterStore(
      settings: models,
      api: ChatApi(
        clientFactory: () => MockClient((_) async {
          requests++;
          throw StateError('A presenter test must never send a model request');
        }),
      ),
    );
    store.conversations
      ..clear()
      ..add(Conversation('原生聊天', [], personaId: store.personas.first.id));
    store.conversation = 0;
  });

  tearDown(() {
    expect(requests, 0);
    store.dispose();
    models.dispose();
  });

  Widget surface({
    ChatUiMode mode = ChatUiMode.wechat,
    bool active = true,
    VoidCallback? back,
    VoidCallback? info,
    ValueChanged<String>? go,
    ValueChanged<String>? onRole,
    ValueChanged<String>? navigate,
    Message? locateMessage,
  }) => MaterialApp(
    home: Scaffold(
      body: SafeArea(
        top: false,
        child: NativeSocialChat(
          mode: mode,
          store: store,
          active: active,
          locateMessage: locateMessage,
          go: go ?? (_) {},
          onRole: onRole,
          navigate: navigate,
          onBack: back ?? () {},
          onInfo: info ?? () {},
        ),
      ),
    ),
  );

  testWidgets(
    'both native presenters preserve per-conversation multiline drafts',
    (tester) async {
      final first = store.conversations.first..draft = '未发送的第一段\n第二行';
      final next = Conversation('第二段', [], personaId: store.personas.first.id)
        ..draft = '另一份草稿';
      store.conversations.add(next);
      await tester.pumpWidget(surface());
      await tester.pumpAndSettle();
      TextField field() => tester.widget<TextField>(
        find.byKey(const ValueKey('social-chat-input')),
      );
      expect(field().controller!.text, first.draft);
      expect(field().maxLines, 4);
      await tester.enterText(
        find.byKey(const ValueKey('social-chat-input')),
        '保存到第一段\n仍未发送',
      );
      store.selectChat(1);
      await tester.pumpAndSettle();
      expect(field().controller!.text, '另一份草稿');
      expect(first.draft, '保存到第一段\n仍未发送');
      await tester.pumpWidget(surface(mode: ChatUiMode.qq));
      await tester.pumpAndSettle();
      store.selectChat(0);
      await tester.pumpAndSettle();
      expect(field().controller!.text, first.draft);
      expect(first.messages, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'queue send and cancellation retain shared store semantics without a model',
    (tester) async {
      final chat = store.conversations.first..confirmBeforeReply = true;
      await tester.pumpWidget(surface(mode: ChatUiMode.qq));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('social-chat-input')),
        '只加入待发送',
      );
      await tester.pump();
      await tester.tap(find.text('发送'));
      await tester.pumpAndSettle();
      expect(chat.queuedMessages.single.text, '只加入待发送');
      expect((store as _PresenterStore).sendModes, [false]);
      expect(find.text('1 条待发送'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('social-chat-input')))
            .controller!
            .text,
        '',
      );
      await tester.tap(find.text('确认发送'));
      await tester.pumpAndSettle();
      expect(chat.queuedMessages, hasLength(1));
      expect((store as _PresenterStore).confirmModes, [false]);
      expect(find.text('请先选择可用模型，待发送消息已保留。'), findsOneWidget);
      await tester.tap(find.text('清空'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(chat.messages, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('only the visible reader clears unread messages', (tester) async {
    final message = Message(false, '后台消息')..unread = true;
    store.messages.add(message);
    await tester.pumpWidget(surface(active: false));
    await tester.pumpAndSettle();
    expect(message.unread, isTrue);
    await tester.pumpWidget(surface(active: true));
    await tester.pumpAndSettle();
    expect(message.unread, isFalse);
    await tester.pumpWidget(surface(active: false));
    await tester.pumpAndSettle();
    message.unread = true;
    store.changed();
    await tester.pumpAndSettle();
    expect(message.unread, isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'new input is limited and oversized restored drafts remain intact on rejected send',
    (tester) async {
      final chat = store.conversations.first..confirmBeforeReply = true;
      await tester.pumpWidget(surface());
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('social-chat-input')),
        'a' * 10020,
      );
      await tester.pump();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('social-chat-input')))
            .controller!
            .text
            .length,
        10000,
      );
      await tester.pumpWidget(const SizedBox());
      final completeDraft = '保存的长草稿' * 2001;
      chat.draft = completeDraft;
      await tester.pumpWidget(surface());
      await tester.pumpAndSettle();
      await tester.tap(find.text('发送'));
      await tester.pumpAndSettle();
      expect(chat.draft, completeDraft);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('social-chat-input')))
            .controller!
            .text,
        completeDraft,
      );
      expect(chat.messages, isEmpty);
      expect(find.text('单条消息最多 10000 字符，完整草稿已保留，请分条发送。'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'social replies remain hidden until the full reply completes and header uses role name',
    (tester) async {
      final chat = store.conversations.first..title = '发送自动生成的标题';
      final pending = Message(false, '尚未完成的正文')..status = 'pending';
      chat.messages.add(pending);
      store.streaming = true;
      await tester.pumpWidget(surface());
      await tester.pumpAndSettle();
      expect(find.text(store.role.name), findsOneWidget);
      expect(find.text(chat.title), findsNothing);
      expect(find.text('尚未完成的正文'), findsNothing);
      expect(find.text('停止'), findsOneWidget);
      pending
        ..text = '完整回复一次呈现'
        ..status = 'complete';
      store.streaming = false;
      store.changed();
      await tester.pumpAndSettle();
      expect(find.text('完整回复一次呈现'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('long records stay lazy and history finds an offscreen message', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    store.messages.addAll([
      for (int i = 0; i < 180; i++)
        Message(
          i.isEven,
          '记录编号 $i\n${List.filled(i % 11 == 0 ? 20 : 2, '不同长度的内容').join('\n')}',
          created: DateTime(2026, 10, 24, 10, 0, i),
        ),
    ]);
    await tester.pumpWidget(surface());
    await tester.pumpAndSettle();
    expect(find.byType(SocialChatSurface).evaluate().length, lessThan(30));
    expect(find.textContaining('记录编号 179'), findsOneWidget);
    await tester.longPress(find.text(store.role.name));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, '搜索这段对话'),
      '记录编号 17\n',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, store.messages[17].text));
    await tester.pumpAndSettle();
    expect(
      find.byKey(
        ValueKey(
          'social-message-${store.messages[17].created.microsecondsSinceEpoch}',
        ),
      ),
      findsOneWidget,
    );
    final rect = tester.getRect(
      find.byKey(
        ValueKey(
          'social-message-${store.messages[17].created.microsecondsSinceEpoch}',
        ),
      ),
    );
    expect(rect.top, lessThan(750));
    expect(rect.bottom, greaterThan(70));
    expect(find.byType(SocialChatSurface).evaluate().length, lessThan(30));
    await tester.tap(find.text('回到最新'));
    await tester.pumpAndSettle();
    expect(find.textContaining('记录编号 179'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('external search locates existing messages on mount and update', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final chat = store.conversations.first;
    chat.messages.addAll([
      for (var i = 0; i < 130; i++)
        Message(
          i.isEven,
          '外部定位 $i\n原记录保持不变',
          created: DateTime(2026, 10, 24, 10, 0, i),
        ),
    ]);
    final oldMessages = List<Message>.of(chat.messages);
    await tester.pumpWidget(surface(locateMessage: chat.messages[8]));
    await tester.pumpAndSettle();
    expect(find.text('外部定位 8\n原记录保持不变'), findsOneWidget);
    expect(tester.getRect(find.text('外部定位 8\n原记录保持不变')).top, lessThan(750));
    await tester.pumpWidget(surface(locateMessage: chat.messages[108]));
    await tester.pumpAndSettle();
    expect(find.text('外部定位 108\n原记录保持不变'), findsOneWidget);
    expect(tester.getRect(find.text('外部定位 108\n原记录保持不变')).top, lessThan(750));
    expect(chat.messages, orderedEquals(oldMessages));
    expect(chat.draft, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'social native CSS hides reasoning in both modes without removing stored reasoning or visible status notices',
    (tester) async {
      final originalShowThinking = appearance.flag('showThinking');
      addTearDown(() => appearance.set('showThinking', originalShowThinking));
      appearance.set('showThinking', true);
      final message = Message(false, '完整正文')
        ..thinking = '保留在原版消息中的推理内容'
        ..contextNotice = '上下文已截断'
        ..error = '模型未开放或已下架'
        ..status = 'failed';
      store.messages.add(message);
      for (final mode in [ChatUiMode.wechat, ChatUiMode.qq]) {
        await tester.pumpWidget(surface(mode: mode));
        await tester.pumpAndSettle();
        expect(find.text(message.text), findsOneWidget);
        expect(find.text('思考过程', skipOffstage: false), findsNothing);
        expect(find.text(message.thinking!, skipOffstage: false), findsNothing);
        expect(find.byType(ExpansionTile, skipOffstage: false), findsNothing);
        expect(find.text(message.contextNotice!), findsOneWidget);
        expect(find.text(message.error!), findsOneWidget);
        expect(message.thinking, '保留在原版消息中的推理内容');
        expect(appearance.flag('showThinking'), isTrue);
      }
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('message status and long press keep context and quote behavior', (
    tester,
  ) async {
    final role = store.personas.last;
    final message = Message(false, '归属于群成员的回复')
      ..authorId = role.id
      ..contextNotice = '上下文已截断'
      ..error = '模型未开放或已下架，请更新模型列表并切换到当前可用模型'
      ..status = 'failed';
    store.messages.add(message);
    store.conversations.first.groupMembers = [store.personas.first.id, role.id];
    await tester.pumpWidget(surface());
    await tester.pumpAndSettle();
    expect(find.text(role.name), findsOneWidget);
    expect(find.text('上下文已截断'), findsOneWidget);
    expect(find.text(message.error!), findsOneWidget);
    await tester.longPress(find.text(message.text));
    await tester.pumpAndSettle();
    await tester.tap(find.text('引用到输入框'));
    await tester.pumpAndSettle();
    expect(store.conversations.first.draft, message.text);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'QQ restores the six-icon toolbar and original two inline tool pages',
    (tester) async {
      tester.view.physicalSize = const Size(430, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final paths = <String>[];
      await tester.pumpWidget(surface(mode: ChatUiMode.qq, go: paths.add));
      await tester.pumpAndSettle();
      for (final label in ['语音识别', '相册', '拍摄照片', '模型助手', '表情包', '更多功能'])
        expect(find.byTooltip(label), findsOneWidget);
      expect(find.text('发送'), findsOneWidget);
      await tester.tap(find.byTooltip('更多功能'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('social-inline-tools')), findsOneWidget);
      for (final label in [
        '语音通话',
        '视频通话',
        '位置',
        '文件',
        '红包',
        '转账',
        '收藏',
        '屏幕分享',
      ])
        expect(find.text(label), findsOneWidget);
      expect(find.text('开发中'), findsOneWidget);
      final video = tester.widget<InkWell>(
        find
            .ancestor(of: find.text('视频通话'), matching: find.byType(InkWell))
            .first,
      );
      expect(video.onTap, isNull);
      await tester.tap(find.byTooltip('更多功能第 2 页'));
      await tester.pumpAndSettle();
      for (final label in ['名片', '礼物', '一起听歌', '描述照片'])
        expect(find.text(label), findsOneWidget);
      await tester.tap(find.byTooltip('更多功能第 1 页'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('语音通话'));
      await tester.pumpAndSettle();
      expect(paths, isEmpty);
      expect(find.text('使用 Skivu 角色语音引擎'), findsOneWidget);
      final portrait = tester.widget<NativeSocialPortrait>(
        find.byType(NativeSocialPortrait).last,
      );
      expect(portrait.size, 86);
      expect(portrait.borderRadius, 12);
      expect(portrait.persona, same(store.personas.first));
      expect(find.byType(AppBar), findsOneWidget);
      await tester.tap(find.text('开始语音通话'));
      await tester.pumpAndSettle();
      expect(paths, ['/call']);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'local location and role cards remain real archive interactions',
    (tester) async {
      await tester.pumpWidget(surface());
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('更多功能'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('位置'));
      await tester.tap(find.text('位置'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, '地点名称'), '本机地点');
      await tester.enterText(
        find.widgetWithText(TextField, '地址或位置描述'),
        '手动填写的位置描述',
      );
      await tester.tap(find.text('保存到聊天'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 300));
      expect(store.conversations.first.interactions.single['kind'], 'location');
      expect(find.text('本机地点'), findsOneWidget);
      await tester.tap(find.byTooltip('更多功能'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('更多功能第 2 页'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('个人名片'));
      await tester.tap(find.text('个人名片'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(ListTile, store.personas.first.name),
      );
      await tester.pumpAndSettle();
      final event = store.conversations.first.interactions.last;
      expect(event['kind'], 'contact');
      expect(event['payload']['roleId'], store.personas.first.id);
      expect(store.messages, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'composer and attachments retain their horizontal gestures before parent back swipe',
    (tester) async {
      tester.view.physicalSize = const Size(430, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var parentDrags = 0;
      store.conversations.first.interactions.add({
        'id': 'native-gesture-location',
        'kind': 'location',
        'created': DateTime.now().toIso8601String(),
        'user': true,
        'payload': {'label': '附件手势', 'address': ''},
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GestureDetector(
              onHorizontalDragEnd: (_) => parentDrags++,
              child: NativeSocialChat(
                mode: ChatUiMode.qq,
                store: store,
                go: (_) {},
                onBack: () {},
                onInfo: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.drag(
        find.byKey(const ValueKey('social-chat-composer')),
        const Offset(140, 0),
      );
      await tester.pumpAndSettle();
      expect(parentDrags, 0);
      await tester.drag(find.text('附件手势'), const Offset(140, 0));
      await tester.pumpAndSettle();
      expect(parentDrags, 0);
      await tester.dragFrom(const Offset(30, 400), const Offset(140, 0));
      await tester.pumpAndSettle();
      expect(parentDrags, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'real gallery image messages expose the same bounded native export',
    (tester) async {
      final calls = <MethodCall>[];
      const channel = MethodChannel('skivu/chat_attachment');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        return false;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      store.messages.add(
        Message(true, '照片')
          ..kind = 'image'
          ..imageData =
              'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAGUlEQVR4nGN0aDjCQApgIkn1qIZRDUNKAwDVAAGkxqTHVQAAAABJRU5ErkJggg==',
      );
      await tester.pumpWidget(surface());
      await tester.pumpAndSettle();
      await tester.longPress(find.byType(SocialChatSurface));
      await tester.pumpAndSettle();
      await tester.tap(find.text('另存图片'));
      await tester.pumpAndSettle();
      expect(calls.single.method, 'save');
      expect(calls.single.arguments['mime'], 'image/png');
      expect(
        (calls.single.arguments['bytes'] as List).length,
        lessThan(2 * 1024 * 1024),
      );
      expect(store.messages, hasLength(1));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('parent keyboard resize leaves composer at available bottom', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(surface());
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 310);
    await tester.pumpAndSettle();
    final composer = tester.getRect(
      find.byKey(const ValueKey('social-chat-composer')),
    );
    expect(composer.bottom, closeTo(590, .5));
    expect(tester.takeException(), isNull);
    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.byKey(const ValueKey('social-chat-composer'))).bottom,
      closeTo(900, .5),
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'native virtual redpacket receives through the durable existing ledger',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        VirtualWallet.storageKey: jsonEncode({
          'id': 'native-wallet-test',
          'balance': 0,
          'entries': [],
          'requests': [],
          'transactions': [],
        }),
      });
      await tester.runAsync(virtualWallet.restore);
      final chat = store.conversations.first, role = store.personas.first;
      expect(
        await tester.runAsync(
          () => virtualWallet.interact(
            requestId: 'native-incoming-test',
            operation: 'create',
            chatId: chat.id,
            roleId: role.id,
            roleName: role.name,
            cents: 250,
            incoming: true,
            kind: 'redpacket',
          ),
        ),
        isNull,
      );
      await tester.pumpWidget(surface());
      await tester.pumpAndSettle();
      expect(find.text('红包 · 角色虚拟钱包'), findsOneWidget);
      await tester.tap(find.text('红包 · 角色虚拟钱包'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('开'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        for (var i = 0; i < 50 && virtualWallet.balance != 250; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 2));
        }
      });
      await tester.pumpAndSettle();
      expect(virtualWallet.balance, 250);
      expect(find.text('已领取'), findsOneWidget);
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      await tester.longPress(find.text('红包 · 角色虚拟钱包'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(chat.hiddenInteractions, contains('native-incoming-test'));
      expect(virtualWallet.balance, 250);
      expect((virtualWallet.snapshot()['transactions'] as List), hasLength(1));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'stored audio attachment has real inline playback controls and full-page export',
    (tester) async {
      store.conversations.first.interactions.add({
        'id': 'native-audio-test',
        'kind': 'audio',
        'user': true,
        'created': DateTime.now().toIso8601String(),
        'payload': {
          'name': '录音.mp3',
          'data': 'data:audio/mpeg;base64,AQID',
          'bytes': 3,
        },
      });
      await tester.pumpWidget(surface());
      await tester.pumpAndSettle();
      expect(find.byType(NativeSocialMediaPreview), findsOneWidget);
      expect(find.byTooltip('播放音频'), findsOneWidget);
      expect(find.byType(Slider), findsOneWidget);
      await tester.tap(find.text('录音.mp3'));
      await tester.pumpAndSettle();
      expect(find.byType(AppBar), findsOneWidget);
      expect(find.text('系统打开'), findsOneWidget);
      expect(find.text('另存'), findsOneWidget);
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      for (final title in ['钱包', '选择模型', '设置']) {
        expect(find.text(title), findsOneWidget);
      }
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      expect(find.text('另存'), findsOneWidget);
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      expect(store.conversations.first.interactions, hasLength(1));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'valid stored role cards delegate full profile without switching chats; removed roles do not',
    (tester) async {
      final chat = store.conversations.first, role = store.personas.first;
      chat.interactions.addAll([
        {
          'id': 'role-card',
          'kind': 'contact',
          'user': true,
          'created': DateTime.now().toIso8601String(),
          'payload': {'roleId': role.id, 'name': '已保存角色'},
        },
        {
          'id': 'removed-role-card',
          'kind': 'contact',
          'user': true,
          'created': DateTime.now().toIso8601String(),
          'payload': {'roleId': 'removed', 'name': '已删除角色'},
        },
      ]);
      final opened = <String>[];
      await tester.pumpWidget(surface(onRole: opened.add));
      await tester.pumpAndSettle();
      await tester.tap(find.text('已保存角色'));
      await tester.pumpAndSettle();
      expect(opened, [role.id]);
      expect(find.byType(AppBar), findsNothing);
      expect(store.conversations[store.conversation], same(chat));
      await tester.tap(find.text('已删除角色'));
      await tester.pumpAndSettle();
      expect(opened, [role.id]);
      expect(find.text('角色已不存在。'), findsOneWidget);
      expect(chat.interactions, hasLength(2));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'location and gift interaction More restores wallet and settings routes without changing drafts',
    (tester) async {
      final paths = <String>[], destinations = <String>[];
      store.conversations.first.draft = '原草稿';
      await tester.pumpWidget(
        surface(mode: ChatUiMode.qq, go: paths.add, navigate: destinations.add),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('更多功能'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('位置'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<AppBar>(find.byType(AppBar)).backgroundColor,
        Colors.white,
      );
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('钱包'));
      await tester.pumpAndSettle();
      expect(destinations, ['wallet']);
      expect(store.conversations.first.draft, '原草稿');
      await tester.tap(find.byTooltip('更多功能'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('更多功能第 2 页'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('礼物'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      expect(paths, ['/settings']);
      expect(store.conversations.first.draft, '原草稿');
      expect(store.conversations.first.interactions, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

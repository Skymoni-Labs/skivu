import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ski/native_social_extras.dart';
import 'package:ski/legacy_social_migration.dart';
import 'package:ski/social_activity.dart';
import 'package:ski/social_post_draft.dart';
import 'package:ski/state.dart';
import 'package:ski/ui_plugins.dart';
import 'package:ski/virtual_wallet.dart';
import 'package:ski/native_social_extra_components.dart';
import 'package:ski/native_social_icons.dart';
import 'package:ski/native_social_portrait.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // No foreground social automation and no model session is started in tests.
    socialActivity.setForeground(false);
    await socialActivity.restore();
  });

  Future<void> open(
    WidgetTester tester,
    String page, {
    ValueChanged<String>? navigate,
    ValueChanged<String>? go,
    ChatUiMode mode = ChatUiMode.wechat,
    Persona? previewRole,
    VoidCallback? onBack,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: NativeSocialExtras(
          page: page,
          draftStore: SocialPostDraftStore(),
          mode: mode,
          previewRole: previewRole,
          navigate: navigate ?? (_) {},
          go: go ?? (_) {},
          onBack: onBack ?? () {},
        ),
      ),
    ),
  );

  test('wallet decimal parser preserves exact cents and bounds', () {
    expect(parseSocialWalletAmount('0'), 0);
    expect(parseSocialWalletAmount('12.3'), 1230);
    expect(parseSocialWalletAmount(' 999999.99 '), 99999999);
    for (final invalid in [
      '-1',
      '01',
      '1.001',
      '.5',
      '1e2',
      '1000000',
      'NaN',
      '',
    ]) {
      expect(parseSocialWalletAmount(invalid), isNull, reason: invalid);
    }
  });

  test('native QR painter roundtrips through image decoder', () async {
    const code = 'skivu://virtual-wallet/test-local-wallet-0123456789';
    final recorder = ui.PictureRecorder();
    SocialQrPainter(code).paint(Canvas(recorder), const Size(220, 220));
    final picture = recorder.endRecording();
    final image = await picture.toImage(220, 220);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    expect(decodeSocialQrImage(bytes!.buffer.asUint8List()), code);
    image.dispose();
    picture.dispose();
  });

  test('QR decoder rejects oversized input and image headers', () {
    expect(
      () => decodeSocialQrImage(Uint8List(5 * 1024 * 1024 + 1)),
      throwsFormatException,
    );
    final wide = img.Image(width: 8193, height: 1);
    expect(
      () => decodeSocialQrImage(img.encodePng(wide)),
      throwsFormatException,
    );
    expect(
      () => decodeSocialQrImage(Uint8List.fromList([1, 2, 3])),
      throwsFormatException,
    );
  });

  test('Skivu QR parsing accepts only exact local identifiers', () {
    (String, String)? parse(String code) =>
        parseSocialCode(code, roleIds: {'local'}, walletId: 'wallet');
    expect(parse('skivu://role/local'), ('role', 'local'));
    expect(parse('skivu://virtual-wallet/wallet'), (
      'virtual-wallet',
      'wallet',
    ));
    for (final invalid in [
      'https://role/local',
      'skivu://role/unknown',
      'skivu://virtual-wallet/other',
      'skivu://role:123/local',
      'skivu://user@role/local',
      'skivu://role/local?redirect=https://evil.test',
      'skivu://role/local#fragment',
      'skivu://role/local/extra',
      'skivu://role/%',
      'skivu://role/${'a' * 501}',
    ]) {
      expect(parse(invalid), isNull, reason: invalid);
    }
  });

  test(
    'post normalization produces a data URI within persisted feed bound',
    () async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawColor(Colors.teal, BlendMode.src);
      final picture = recorder.endRecording();
      final image = await picture.toImage(4, 4);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final uri = await normalizeSocialPhoto(bytes!.buffer.asUint8List());
      expect(uri.startsWith('data:image/png;base64,'), isTrue);
      expect(uri.length, lessThanOrEqualTo(150000));
      expect(base64Decode(uri.split(',').last), isNotEmpty);
      image.dispose();
      picture.dispose();
    },
  );

  testWidgets('compose publishes to QQ and rejects empty drafts', (
    tester,
  ) async {
    final routes = <String>[];
    await open(tester, 'compose', mode: ChatUiMode.qq, navigate: routes.add);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
    await tester.tap(find.text('发表'));
    await tester.pump();
    expect(routes, isEmpty);
    await tester.enterText(find.byType(TextField), 'QQ真实存储');
    await tester.runAsync(() async {
      await tester.tap(find.text('发表'));
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    await tester.pumpAndSettle();
    expect(
      socialActivity.feed('qq').map((p) => p['text']),
      contains('QQ真实存储'),
      reason: tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .join('|'),
    );
    expect(routes, ['moments']);
    final post = socialActivity.feed('qq').first;
    expect(post['text'], 'QQ真实存储');
    socialActivity.interact('delete', post['id'] as String);
    await tester.pumpAndSettle();
  });

  testWidgets(
    'feed reads persisted posts, likes, comments and deletes own posts',
    (tester) async {
      const text = '本地原生动态验收';
      expect(socialActivity.publish('wx', text, []), isNull);
      final id = socialActivity.feed('wx').first['id'] as String;
      await open(tester, 'moments');
      expect(find.text(text), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('动态操作').first);
      await tester.pump();
      await tester.tap(find.text('赞').first);
      await tester.pump();
      expect(socialActivity.feed('wx').first['likes'], contains('self'));
      await tester.tap(find.bySemanticsLabel('动态操作').first);
      await tester.pump();
      await tester.tap(find.text('评论').first);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '已保存的评论');
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(
        (socialActivity.feed('wx').first['comments'] as List).last['text'],
        '已保存的评论',
      );
      await tester.tap(find.text('删除').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认删除本地动态'));
      await tester.pumpAndSettle();
      expect(socialActivity.feed('wx').any((p) => p['id'] == id), isFalse);
    },
  );

  testWidgets('favorites use actual bookmarked chat messages', (tester) async {
    final message = Message(true, '原生收藏验收', bookmarked: true);
    final chat = Conversation('本地收藏对话', [message]);
    demo.conversations.add(chat);
    addTearDown(() => demo.conversations.remove(chat));
    await open(tester, 'favorites');
    expect(find.text('原生收藏验收'), findsOneWidget);
    await tester.tap(find.text('原生收藏验收'));
    await tester.pumpAndSettle();
    expect(find.text('来自本地收藏对话'), findsOneWidget);
  });

  testWidgets('native settings connect existing host settings routes', (
    tester,
  ) async {
    final routes = <String>[];
    await open(tester, 'settings', go: routes.add, mode: ChatUiMode.qq);
    await tester.tap(find.text('社交与群聊'));
    await tester.tap(find.text('聊天外观'));
    expect(routes, ['/settings/social', '/settings/appearance']);
  });

  testWidgets(
    'cashier uses the real wallet identifier and shows virtual scope',
    (tester) async {
      await open(tester, 'cashier');
      expect(
        tester.widget<NativeSocialQr>(find.byType(NativeSocialQr)).data,
        'skivu://virtual-wallet/${virtualWallet.id}',
      );
      expect(
        tester.widget<NativeSocialQr>(find.byType(NativeSocialQr)).size,
        240,
      );
      await tester.drag(find.byType(ListView), const Offset(0, -240));
      await tester.pumpAndSettle();
      expect(find.text('角色互动虚拟钱包'), findsOneWidget);
      await tester.tap(find.text('向角色付款'));
      await tester.pumpAndSettle();
      expect(find.text('转账金额'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('social-finance-amount')),
        findsOneWidget,
      );
      expect(find.text('角色互动 · 虚拟资金，仅保存在此设备'), findsOneWidget);
    },
  );

  testWidgets('calls use saved call interactions and disable video', (
    tester,
  ) async {
    final chat = Conversation('原生通话记录', [])
      ..interactions.add({
        'id': 'saved-native-call',
        'kind': 'call',
        'created': '2026-10-24T10:30:00',
        'payload': {'duration': 42, 'video': false},
      });
    demo.conversations.add(chat);
    addTearDown(() => demo.conversations.remove(chat));
    final routes = <String>[];
    await open(tester, 'calls', go: routes.add);
    expect(find.text('原生通话记录'), findsOneWidget);
    final video = tester.widget<SocialExtraMenuRow>(
      find.widgetWithText(SocialExtraMenuRow, '视频通话'),
    );
    expect(video.enabled, isFalse);
    await tester.tap(find.text('语音通话'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始语音通话'));
    expect(routes, ['/call']);
  });

  testWidgets(
    'social profile editor merges four fields with the existing role card',
    (tester) async {
      final before = Map<String, String>.of(demo.userCard);
      addTearDown(() => demo.userCard = before);
      demo.userCard = {
        '称呼': '保留称呼',
        '身份与背景': '保留背景',
        '自定义字段': '保留扩展',
        '社交账号': 'old-local',
      };
      await open(tester, 'profile');
      await tester.pumpAndSettle();
      final fields = find.byType(TextField);
      expect(fields, findsNWidgets(4));
      await tester.enterText(fields.at(0), '新称呼');
      await tester.enterText(fields.at(1), 'new-local');
      await tester.enterText(fields.at(2), '本机签名');
      await tester.enterText(fields.at(3), '本机地区');
      await tester.scrollUntilVisible(
        find.text('保存资料'),
        180,
        scrollable: find
            .descendant(
              of: find.byType(SocialNativeProfileForm),
              matching: find.byWidgetPredicate(
                (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
              ),
            )
            .first,
      );
      await tester.tap(find.text('保存资料'));
      await tester.pump();
      expect(demo.userCard['社交账号'], 'new-local');
      expect(demo.userCard['个性签名'], '本机签名');
      expect(demo.userCard['地区'], '本机地区');
      expect(demo.userCard['称呼'], '新称呼');
      expect(demo.userCard['身份与背景'], '保留背景');
      expect(demo.userCard['自定义字段'], '保留扩展');
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'settings expose migration failures and retry without hiding the archive',
    (tester) async {
      final status = legacySocialMigration.status;
      final error = legacySocialMigration.error;
      addTearDown(() {
        legacySocialMigration.status = status;
        legacySocialMigration.error = error;
      });
      legacySocialMigration.status = LegacySocialStatus.failed;
      legacySocialMigration.error = '旧记录已保留，可重试验收';
      await open(tester, 'settings');
      await tester.drag(find.byType(ListView), const Offset(0, -400));
      await tester.pumpAndSettle();
      expect(find.text('旧记录已保留，可重试验收'), findsOneWidget);
      expect(find.text('重新检查并迁移'), findsOneWidget);
    },
  );

  testWidgets(
    'secondary headers retain 52px height and centered title at mobile width',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await open(tester, 'wallet');
      expect(
        tester
            .getSize(find.byKey(const ValueKey('social-extra-header')))
            .height,
        52,
      );
      expect(tester.getCenter(find.text('钱包')).dx, 195);
      expect(
        tester.getSize(find.byKey(const ValueKey('social-extra-header'))).width,
        390,
      );
      expect(find.byType(ListTile), findsNothing);
    },
  );

  testWidgets(
    'all secondary pages lay out in both modes on narrow mobile viewports',
    (tester) async {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final mode in [ChatUiMode.wechat, ChatUiMode.qq]) {
        for (final page in [
          'moments',
          'compose',
          'albums',
          'favorites',
          'services',
          'wallet',
          'wallet-records',
          'cashier',
          'scan',
          'profile',
          'calls',
          'call-preview',
          'settings',
          'cards',
          'status',
          'miniapps',
          'files',
          'privacy',
        ]) {
          await open(tester, page, mode: mode);
          await tester.pump(const Duration(milliseconds: 30));
          expect(tester.takeException(), isNull, reason: '${mode.name}/$page');
          expect(
            find.byType(ListTile),
            findsNothing,
            reason: '${mode.name}/$page',
          );
        }
      }
    },
  );

  testWidgets(
    'compose retains author, image add menu, six original illustrations and local visibility entries',
    (tester) async {
      await open(tester, 'compose');
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pumpAndSettle();
      expect(find.text('所在位置'), findsOneWidget);
      expect(find.text('谁可以看'), findsOneWidget);
      expect(find.text('不显示位置'), findsOneWidget);
      expect(find.bySemanticsLabel('添加动态图片'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('添加动态图片'));
      await tester.pumpAndSettle();
      expect(find.text('从相册选择'), findsOneWidget);
      expect(find.text('拍摄照片'), findsOneWidget);
      for (final art in [
        'coast',
        'flowers',
        'clouds',
        'coffee',
        'mountain',
        'sunset',
      ]) {
        expect(find.bySemanticsLabel('选择内置插画$art'), findsOneWidget);
      }
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
    },
  );

  testWidgets(
    'WeChat settings preserve every legacy section and preview entry',
    (tester) async {
      await open(tester, 'settings');
      final visible = <String>{};
      for (var i = 0; i < 4; i++) {
        visible.addAll(
          tester
              .widgetList<Text>(find.byType(Text))
              .map((t) => t.data)
              .whereType<String>(),
        );
        await tester.drag(find.byType(ListView), const Offset(0, -320));
        await tester.pumpAndSettle();
      }
      expect(
        visible,
        containsAll([
          '社交与群聊',
          '账号与安全',
          '青少年模式',
          '关怀模式',
          '新消息通知',
          '聊天',
          '通用',
          '隐私',
          '朋友权限',
          '个人信息与权限',
          '帮助与反馈',
          '关于微信',
          '原版全部设置',
          '回到原版工作区',
        ]),
      );
    },
  );

  testWidgets(
    'QQ settings retain five local font choices without a global appearance mutation',
    (tester) async {
      await open(tester, 'settings', mode: ChatUiMode.qq);
      expect(find.text('新消息通知'), findsOneWidget);
      expect(find.text('免打扰模式'), findsOneWidget);
      await tester.tap(find.text('字体与排版'));
      await tester.pumpAndSettle();
      for (final font in [13, 14, 15, 16, 18])
        expect(find.text('$font px'), findsOneWidget);
      expect(find.text('仅调整微信/QQ社交界面消息字号，不修改原版全局外观。'), findsOneWidget);
    },
  );

  testWidgets(
    'albums include cross-chat image and video attachments and respect hidden and clear boundaries',
    (tester) async {
      final chat = Conversation('媒体档案', [])
        ..interactionsClearedAt = DateTime(2026, 10, 23);
      for (final row in [
        ('visible-image', 'image', '本机照片.png', '2026-10-24T10:00:00'),
        ('visible-video', 'video', '本机视频.mp4', '2026-10-24T10:01:00'),
        ('hidden-image', 'image', '隐藏照片.png', '2026-10-24T10:00:00'),
        ('old-image', 'image', '清空前照片.png', '2026-10-22T10:00:00'),
      ]) {
        chat.interactions.add({
          'id': row.$1,
          'kind': row.$2,
          'created': row.$4,
          'payload': {
            'name': row.$3,
            'data': row.$2 == 'image'
                ? 'data:image/png;base64,AA=='
                : 'data:video/mp4;base64,AA==',
            'bytes': 1,
          },
        });
      }
      chat.hiddenInteractions.add('hidden-image');
      demo.conversations.add(chat);
      addTearDown(() => demo.conversations.remove(chat));
      await open(tester, 'albums');
      expect(find.text('本机照片.png'), findsOneWidget);
      expect(find.text('本机视频.mp4'), findsOneWidget);
      expect(find.text('隐藏照片.png'), findsNothing);
      expect(find.text('清空前照片.png'), findsNothing);
    },
  );

  test(
    'all reused line icon identifiers exist in the original icon registry',
    () {
      expect(
        NativeSocialIcon.names,
        containsAll([
          'interaction-back',
          'camera',
          'wallet',
          'qr',
          'list',
          'transfer',
          'envelope',
          'image',
          'video',
          'music',
          'folder',
          'cloud',
          'box',
          'check',
          'sliders',
          'user',
          'smile',
          'right',
          'heart',
          'chat',
          'plus',
          'close',
          'pin',
          'users',
          'star',
          'settings',
        ]),
      );
    },
  );
  testWidgets(
    'contact call preview remains a timed local demo with mute, hangup and disabled video',
    (tester) async {
      final role = Persona(
        '本地演示角色',
        '仅本机',
        '',
        '测试',
        Colors.teal,
        Icons.person_outline,
        id: 'local-call-preview-role',
      );
      var returned = 0;
      final chats = demo.conversations.fold<int>(
        0,
        (n, c) => n + c.interactions.where((e) => e['kind'] == 'call').length,
      );
      final routes = <String>[];
      await open(
        tester,
        'call-preview',
        previewRole: role,
        onBack: () => returned++,
        go: routes.add,
      );
      expect(find.text('本地演示角色'), findsOneWidget);
      expect(find.text('等待对方接听…'), findsOneWidget);
      expect(find.text('本机界面演示，不连接微信或QQ，不发起真实通话。'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('等待对方接听…'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('界面演示 · 00:00'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      expect(find.text('界面演示 · 00:05'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('social-call-preview-mic')));
      await tester.pump();
      expect(find.text('麦克风已静音（本地演示）'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('social-call-preview-mic')));
      await tester.pump();
      expect(find.text('麦克风已静音（本地演示）'), findsNothing);
      final video = tester.widget<GestureDetector>(
        find.byKey(const ValueKey('social-call-preview-video')),
      );
      expect(video.onTap, isNull);
      expect(find.text('视频通话开发中'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('social-call-preview-hangup')),
      );
      await tester.pump();
      expect(returned, 1);
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('界面演示 · 00:05'), findsOneWidget);
      expect(routes, isEmpty);
      expect(
        demo.conversations.fold<int>(
          0,
          (n, c) => n + c.interactions.where((e) => e['kind'] == 'call').length,
        ),
        chats,
      );
    },
  );
  testWidgets(
    'screenshot parity keeps compact unfilled compose and the three wallet rows with preserved extra actions',
    (tester) async {
      await open(tester, 'compose');
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.minLines, 1);
      expect(field.decoration!.filled, isFalse);
      expect(find.text('发表'), findsOneWidget);
      await open(tester, 'wallet');
      expect(find.text('零钱明细'), findsOneWidget);
      expect(find.text('收付款'), findsOneWidget);
      expect(find.text('设置虚拟零钱'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('更多钱包功能'));
      await tester.pumpAndSettle();
      expect(find.text('模拟角色转账'), findsOneWidget);
      expect(find.text('模拟角色红包'), findsOneWidget);
    },
  );
  testWidgets(
    'published screenshot details keep centered composer, 44px portrait, dashed image tile and missing-only signature fallback',
    (tester) async {
      final before = Map<String, String>.of(demo.userCard);
      addTearDown(() => demo.userCard = before);
      demo.userCard.remove('个性签名');
      await open(tester, 'moments');
      expect(find.text('生活很慢，喜欢的事要慢慢来。'), findsOneWidget);
      demo.userCard['个性签名'] = '';
      demo.changed();
      await tester.pump();
      expect(find.text('生活很慢，喜欢的事要慢慢来。'), findsNothing);
      await open(tester, 'compose');
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<NativeSocialPortrait>(
              find.byType(NativeSocialPortrait).first,
            )
            .size,
        44,
      );
      expect(find.byType(SocialExtraAddPhotoTile), findsOneWidget);
      final publish = find.widgetWithText(SocialExtraButton, '发表');
      expect(
        tester.getCenter(publish).dx,
        tester.view.physicalSize.width / tester.view.devicePixelRatio / 2,
      );
      expect(tester.getSize(publish).width, 180);
    },
  );
}

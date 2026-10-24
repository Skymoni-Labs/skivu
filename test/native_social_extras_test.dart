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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // No foreground social automation and no model session is started in tests.
    socialActivity.setForeground(false);
    await socialActivity.restore();
    await socialPostDrafts.read('wx');
  });

  Future<void> open(
    WidgetTester tester,
    String page, {
    ValueChanged<String>? navigate,
    ValueChanged<String>? go,
    ChatUiMode mode = ChatUiMode.wechat,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: NativeSocialExtras(
          page: page,
          mode: mode,
          navigate: navigate ?? (_) {},
          go: go ?? (_) {},
          onBack: () {},
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
      await tester.tap(find.text('赞').first);
      await tester.pump();
      expect(socialActivity.feed('wx').first['likes'], contains('self'));
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
      await tester.tap(find.widgetWithText(TextButton, '删除').last);
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
    expect(find.text('本地收藏对话'), findsOneWidget);
  });

  testWidgets('native settings connect existing host settings routes', (
    tester,
  ) async {
    final routes = <String>[];
    await open(tester, 'settings', go: routes.add);
    await tester.tap(find.text('社交与自动互动'));
    await tester.tap(find.text('外观设置'));
    expect(routes, ['/settings/social', '/settings/appearance']);
  });

  testWidgets(
    'cashier uses the real wallet identifier and shows virtual scope',
    (tester) async {
      await open(tester, 'cashier');
      expect(
        find.text('skivu://virtual-wallet/${virtualWallet.id}'),
        findsOneWidget,
      );
      await tester.drag(find.byType(ListView), const Offset(0, -240));
      await tester.pumpAndSettle();
      expect(find.text('角色互动虚拟钱包，不连接支付网络。'), findsOneWidget);
      await tester.tap(find.text('向角色付款'));
      await tester.pumpAndSettle();
      expect(find.text('虚拟金额'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, '-3');
      await tester.tap(find.text('确认保存'));
      await tester.pumpAndSettle();
      expect(find.text('请输入有效金额，最多两位小数'), findsOneWidget);
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
    final video = tester.widget<ListTile>(
      find.widgetWithText(ListTile, '视频通话'),
    );
    expect(video.enabled, isFalse);
    await tester.tap(find.text('发起语音通话'));
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
      await tester.tap(find.text('编辑社交资料'));
      await tester.pumpAndSettle();
      final fields = find.byType(TextField);
      expect(fields, findsNWidgets(4));
      await tester.enterText(fields.at(0), 'new-local');
      await tester.enterText(fields.at(1), '本机签名');
      await tester.enterText(fields.at(2), '本机地区');
      await tester.enterText(fields.at(3), '在线');
      await tester.ensureVisible(find.text('保存社交资料'));
      await tester.tap(find.text('保存社交资料'));
      await tester.pump();
      expect(demo.userCard['社交账号'], 'new-local');
      expect(demo.userCard['个性签名'], '本机签名');
      expect(demo.userCard['地区'], '本机地区');
      expect(demo.userCard['个人状态'], '在线');
      expect(demo.userCard['称呼'], '保留称呼');
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
}

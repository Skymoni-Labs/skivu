import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ski/model_settings.dart';
import 'package:ski/native_social_finance.dart';
import 'package:ski/state.dart';
import 'package:ski/ui_plugins.dart';
import 'package:ski/virtual_wallet.dart';
import 'real_chat_store_test.dart' show MemoryChats;

void main() {
  late DemoStore store;
  late ModelSettings models;
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await virtualWallet.restore();
  });
  setUp(() {
    models = ModelSettings();
    store = DemoStore(settings: models, storage: MemoryChats());
    store.conversations
      ..clear()
      ..add(Conversation('独立会话', [], personaId: store.personas.first.id));
    store.conversation = 0;
  });
  tearDown(() {
    store.dispose();
    models.dispose();
  });
  Future<void> finishWrites(WidgetTester tester) async {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets(
    'outgoing receipt preserves waiting body, creation time and full-page more actions',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        VirtualWallet.storageKey: jsonEncode({
          'id': 'native-finance-wallet',
          'balance': 1000,
          'entries': [],
          'requests': [],
          'transactions': [],
        }),
      });
      await tester.runAsync(virtualWallet.restore);
      await tester.runAsync(
        () => virtualWallet.interact(
          requestId: 'native-outgoing-test',
          operation: 'create',
          chatId: store.conversations.first.id,
          roleId: store.personas.first.id,
          roleName: store.personas.first.name,
          kind: 'transfer',
          cents: 250,
        ),
      );
      final transaction = Map<String, dynamic>.from(
            (virtualWallet.snapshot()['transactions'] as List).single,
          ),
          navigated = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showNativeSocialReceipt(
                  context,
                  transaction,
                  mode: ChatUiMode.qq,
                  store: store,
                  navigate: navigated.add,
                ),
                child: const Text('打开详情'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开详情'));
      await tester.pumpAndSettle();
      expect(find.text('等待对方确认收款'), findsOneWidget);
      expect(find.text('确认收款'), findsNothing);
      expect(find.text('模拟角色收款'), findsNothing);
      expect(
        find.text(
          (transaction['created'] as String)
              .replaceFirst('T', ' ')
              .substring(0, 19),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      for (final label in ['模拟角色收款', '撤回虚拟资金', '钱包', '选择模型', '设置'])
        expect(find.text(label), findsOneWidget);
      await tester.tap(find.text('钱包'));
      await tester.pumpAndSettle();
      expect(navigated, ['wallet']);
      expect(find.text('打开详情'), findsOneWidget);
      expect(
        (virtualWallet.snapshot()['transactions'] as List).single['state'],
        'pending',
      );
      await tester.tap(find.text('打开详情'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('模拟角色收款'));
      await tester.pumpAndSettle();
      await finishWrites(tester);
      expect(
        (virtualWallet.snapshot()['transactions'] as List).single['state'],
        'received',
      );
      expect(virtualWallet.balance, 750);
      expect(find.text('已收款'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

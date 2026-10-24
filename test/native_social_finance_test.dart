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
  var created = 0;
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await virtualWallet.restore();
  });
  setUp(() {
    models = ModelSettings();
    store = DemoStore(settings: models, storage: MemoryChats());
    store.conversations
      ..clear()
      ..add(Conversation('A会话', [], personaId: store.personas.first.id));
    store.conversation = 0;
    created = 0;
  });
  tearDown(() {
    store.dispose();
    models.dispose();
  });
  Future<void> mount(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({
      VirtualWallet.storageKey: jsonEncode({
        'id': 'native-finance-wallet',
        'balance': 0,
        'entries': [],
        'requests': [],
        'transactions': [],
      }),
    });
    await tester.runAsync(virtualWallet.restore);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showNativeSocialFinance(
                context,
                mode: ChatUiMode.qq,
                kind: 'transfer',
                incoming: true,
                store: store,
                onCreated: () => created++,
              ),
              child: const Text('打开转账'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开转账'));
    await tester.pumpAndSettle();
  }

  Future<void> finishWrites(WidgetTester tester) async {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets(
    'incoming role transfer creates pending transaction before receipt credits its own chat',
    (tester) async {
      await mount(tester);
      expect(find.byType(AppBar), findsOneWidget);
      expect(tester.widget<AppBar>(find.byType(AppBar)).toolbarHeight, 54);
      await tester.tap(find.text('1'));
      await tester.tap(find.text('0'));
      await tester.pump();
      await tester.ensureVisible(find.text('转账').last);
      await tester.tap(find.text('转账').last);
      await tester.pumpAndSettle();
      await finishWrites(tester);
      final transactions = virtualWallet.snapshot()['transactions'] as List;
      expect(transactions, hasLength(1));
      final transaction = Map<String, dynamic>.from(transactions.single);
      expect(transaction['state'], 'pending');
      expect(transaction['chatId'], store.conversations.first.id);
      expect(transaction['roleId'], store.personas.first.id);
      expect(transaction['cents'], 1000);
      expect(virtualWallet.balance, 0);
      expect(created, 1);
      final context = tester.element(find.text('打开转账'));
      showNativeSocialReceipt(
        context,
        transaction,
        mode: ChatUiMode.qq,
        store: store,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认收款'));
      await tester.pumpAndSettle();
      await finishWrites(tester);
      expect(virtualWallet.balance, 1000);
      expect(
        (virtualWallet.snapshot()['transactions'] as List).single['state'],
        'received',
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'switching selected chat rejects the open form and never puts A transfer into B',
    (tester) async {
      await mount(tester);
      final second = Conversation('B会话', [], personaId: store.personas.last.id);
      store.conversations.add(second);
      store.selectChat(1);
      await tester.tap(find.text('1'));
      await tester.pump();
      await tester.ensureVisible(find.text('转账').last);
      await tester.tap(find.text('转账').last);
      await tester.pumpAndSettle();
      expect(find.text('对话已切换，请返回后重新操作。'), findsOneWidget);
      expect(virtualWallet.snapshot()['transactions'], isEmpty);
      expect(created, 0);
      expect(second.messages, isEmpty);
      expect(second.interactions, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

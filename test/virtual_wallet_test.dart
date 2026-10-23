import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ski/virtual_wallet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(
    () => SharedPreferences.setMockInitialValues({
      'chat-archive': 'must remain unchanged',
    }),
  );
  test(
    'chat transfer and red packet receipt/refund are atomic and replay-safe',
    () async {
      final wallet = VirtualWallet();
      await wallet.restore();
      await wallet.change(
        requestId: 'fund-wallet-001',
        operation: 'set',
        cents: 1000,
      );
      expect(
        await wallet.interact(
          requestId: 'transfer-local-001',
          operation: 'create',
          chatId: 'chat-a',
          roleId: 'role-a',
          kind: 'transfer',
          cents: 250,
        ),
        isNull,
      );
      expect(wallet.balance, 750);
      await wallet.interact(
        requestId: 'transfer-local-001',
        operation: 'create',
        chatId: 'chat-a',
        roleId: 'role-a',
        kind: 'transfer',
        cents: 250,
      );
      expect(wallet.balance, 750);
      expect(
        await wallet.interact(
          requestId: 'wrong-chat-001',
          operation: 'refund',
          chatId: 'chat-b',
          roleId: 'role-a',
          transactionId: 'transfer-local-001',
        ),
        isNotNull,
      );
      expect(wallet.balance, 750);
      await Future.wait([
        for (var i = 0; i < 3; i++)
          wallet.interact(
            requestId: 'refund-local-001',
            operation: 'refund',
            chatId: 'chat-a',
            roleId: 'role-a',
            transactionId: 'transfer-local-001',
          ),
      ]);
      expect(wallet.balance, 1000);
      await wallet.interact(
        requestId: 'redpacket-local-001',
        operation: 'create',
        chatId: 'chat-a',
        roleId: 'role-a',
        kind: 'redpacket',
        cents: 99,
      );
      await wallet.interact(
        requestId: 'receive-local-001',
        operation: 'receive',
        chatId: 'chat-a',
        roleId: 'role-a',
        transactionId: 'redpacket-local-001',
      );
      expect(wallet.balance, 901);
      await wallet.interact(
        requestId: 'refund-used-001',
        operation: 'refund',
        chatId: 'chat-a',
        roleId: 'role-a',
        transactionId: 'redpacket-local-001',
      );
      expect(wallet.balance, 901);
      final restored = VirtualWallet();
      await restored.restore();
      expect(restored.balance, 901);
      expect(
        (restored.snapshot()['transactions'] as List).first['state'],
        'received',
      );
      expect(
        (restored.snapshot()['transactions'] as List).last['state'],
        'refunded',
      );
      wallet.dispose();
      restored.dispose();
    },
  );
  test('incoming virtual funds credit exactly once when accepted', () async {
    final wallet = VirtualWallet();
    await wallet.restore();
    expect(
      await wallet.interact(
        requestId: 'incoming-local-001',
        operation: 'create',
        chatId: 'chat-a',
        roleId: 'role-a',
        kind: 'redpacket',
        cents: 100,
        incoming: true,
      ),
      isNull,
    );
    expect(wallet.balance, 0);
    await wallet.interact(
      requestId: 'accept-local-001',
      operation: 'receive',
      chatId: 'chat-a',
      roleId: 'role-a',
      transactionId: 'incoming-local-001',
    );
    await wallet.interact(
      requestId: 'accept-local-002',
      operation: 'receive',
      chatId: 'chat-a',
      roleId: 'role-a',
      transactionId: 'incoming-local-001',
    );
    expect(wallet.balance, 100);
    expect(
      await wallet.interact(
        requestId: 'insufficient-001',
        operation: 'create',
        chatId: 'chat-a',
        roleId: 'role-a',
        cents: 101,
      ),
      contains('不足'),
    );
    expect(wallet.balance, 100);
    expect(wallet.snapshot()['transactions'], hasLength(1));
    wallet.dispose();
  });
  test(
    'virtual balance, identity and ledger restore without touching chats',
    () async {
      final wallet = VirtualWallet();
      await wallet.restore();
      final id = wallet.id;
      expect(wallet.balance, 0);
      expect(
        await wallet.change(
          requestId: 'balance-001',
          operation: 'set',
          cents: 12345,
        ),
        isNull,
      );
      expect(
        await wallet.change(
          requestId: 'receive-001',
          operation: 'receive',
          cents: 105,
          roleId: 'r',
          roleName: '角色',
        ),
        isNull,
      );
      expect(
        await wallet.change(
          requestId: 'payment-001',
          operation: 'pay',
          cents: 250,
          roleId: 'r',
          roleName: '角色',
        ),
        isNull,
      );
      expect(wallet.balance, 12200);
      final restored = VirtualWallet();
      await restored.restore();
      expect(restored.id, id);
      expect(restored.balance, 12200);
      expect((restored.snapshot()['entries'] as List).first['cents'], -250);
      expect(
        (await SharedPreferences.getInstance()).getString('chat-archive'),
        'must remain unchanged',
      );
      wallet.dispose();
      restored.dispose();
    },
  );
  test(
    'concurrent duplicate submissions debit only once, including after restart',
    () async {
      final wallet = VirtualWallet();
      await wallet.restore();
      await wallet.change(
        requestId: 'balance-002',
        operation: 'set',
        cents: 1000,
      );
      await Future.wait([
        for (var i = 0; i < 3; i++)
          wallet.change(
            requestId: 'payment-002',
            operation: 'pay',
            cents: 99,
            roleId: 'r',
          ),
      ]);
      expect(wallet.balance, 901);
      final restored = VirtualWallet();
      await restored.restore();
      await restored.change(
        requestId: 'payment-002',
        operation: 'pay',
        cents: 99,
        roleId: 'r',
      );
      expect(restored.balance, 901);
      wallet.dispose();
      restored.dispose();
    },
  );
  test(
    'invalid, insufficient and overflowing virtual amounts do not change the ledger',
    () async {
      final wallet = VirtualWallet();
      await wallet.restore();
      for (final row in [
        ('payment-003', 'pay', 1),
        ('receive-003', 'receive', -1),
        ('unknown-003', 'unknown', 0),
        ('too-big-003', 'set', 100000000),
      ]) {
        expect(
          await wallet.change(
            requestId: row.$1,
            operation: row.$2,
            cents: row.$3,
            roleId: 'r',
          ),
          isNotNull,
        );
      }
      expect(wallet.balance, 0);
      expect(wallet.snapshot()['entries'], isEmpty);
      wallet.dispose();
    },
  );
  test(
    'corrupt records are kept and cannot silently become a fresh spendable wallet',
    () async {
      final raw = jsonEncode({'balance': -1, 'id': 'broken-wallet'});
      SharedPreferences.setMockInitialValues({VirtualWallet.storageKey: raw});
      final wallet = VirtualWallet();
      await wallet.restore();
      expect(wallet.error, isNotNull);
      expect(
        await wallet.change(
          requestId: 'balance-004',
          operation: 'set',
          cents: 10,
        ),
        isNotNull,
      );
      expect(
        (await SharedPreferences.getInstance()).getString(
          VirtualWallet.storageKey,
        ),
        raw,
      );
      wallet.dispose();
    },
  );
}

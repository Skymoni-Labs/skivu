import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _walletId() {
  final random = Random.secure();
  return List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

/// Fictional role-play ledger. No account, payment API, or model calls.
class VirtualWallet extends ChangeNotifier {
  static const storageKey = 'skivu.virtual-wallet.v1';
  static const maxBalance = 99999999;
  int balance = 0, revision = 0;
  String id = _walletId();
  String? error;
  bool _healthy = true;
  List<Map<String, dynamic>> _entries = [];
  List<String> _requests = [];
  List<Map<String, dynamic>> _transactions = [];
  Future<void> _writes = Future.value();
  Map<String, dynamic> snapshot() => {
    'id': id,
    'balanceCents': balance,
    'entries': _entries,
    'error': error,
    'transactions': _transactions
        .map((t) => Map<String, dynamic>.from(t))
        .toList(),
  };
  Future<void> restore() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(storageKey);
      if (raw != null) {
        final data = jsonDecode(raw) as Map;
        final amount = data['balance'];
        if (amount is! int ||
            amount < 0 ||
            amount > maxBalance ||
            data['id'] is! String)
          throw const FormatException();
        balance = amount;
        id = data['id'] as String;
        _entries = (data['entries'] as List)
            .whereType<Map>()
            .take(100)
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
        _requests = (data['requests'] as List)
            .whereType<String>()
            .take(200)
            .toList();
        _transactions =
            (data['transactions'] is List ? data['transactions'] as List : [])
                .whereType<Map>()
                .where(
                  (t) =>
                      t['id'] is String &&
                      t['chatId'] is String &&
                      t['roleId'] is String &&
                      t['cents'] is int &&
                      t['cents'] > 0 &&
                      t['cents'] <= maxBalance &&
                      ['transfer', 'redpacket', 'gift'].contains(t['kind']) &&
                      [
                        'pending',
                        'received',
                        'refunded',
                      ].contains(t['state']) &&
                      DateTime.tryParse(
                            t['created'] is String ? t['created'] : '',
                          ) !=
                          null,
                )
                .take(500)
                .map((t) => Map<String, dynamic>.from(t))
                .toList();
      } else {
        final failure = await change(
          requestId: _walletId(),
          operation: 'set',
          cents: 0,
        );
        if (failure != null) {
          error = failure;
          _healthy = false;
        }
      }
    } catch (_) {
      error = '虚拟钱包记录读取失败，请先保留本机数据。';
      _healthy = false;
    }
    notifyListeners();
  }

  Future<String?> change({
    required String requestId,
    required String operation,
    required int cents,
    String roleId = '',
    String roleName = '',
    String note = '',
  }) async {
    String? failure;
    _writes = _writes.then((_) async {
      if (!_healthy) {
        failure = error;
        return;
      }
      if (_requests.contains(requestId)) return;
      if (requestId.length < 8 ||
          requestId.length > 100 ||
          cents < 0 ||
          cents > maxBalance ||
          !['set', 'pay', 'receive'].contains(operation) ||
          note.length > 100 ||
          (operation != 'set' && (roleId.isEmpty || cents == 0))) {
        failure = '请填写有效的虚拟金额和角色。';
        return;
      }
      final next = switch (operation) {
        'set' => cents,
        'pay' => balance - cents,
        _ => balance + cents,
      };
      if (next < 0) {
        failure = '虚拟零钱余额不足。';
        return;
      }
      if (next > maxBalance) {
        failure = '超出虚拟钱包金额上限。';
        return;
      }
      final delta = next - balance;
      final entries = [
        if (delta != 0)
          {
            'id': requestId,
            'kind': operation,
            'cents': delta,
            'balanceAfter': next,
            'roleId': roleId,
            'roleName': roleName,
            'note': note,
            'created': DateTime.now().toIso8601String(),
          },
        ..._entries,
      ].take(100).toList();
      final requests = [requestId, ..._requests].take(200).toList();
      try {
        if (!await (await SharedPreferences.getInstance()).setString(
          storageKey,
          jsonEncode({
            'id': id,
            'balance': next,
            'entries': entries,
            'requests': requests,
            'transactions': _transactions,
          }),
        )) {
          throw StateError('not saved');
        }
        balance = next;
        _entries = entries;
        _requests = requests;
        error = null;
        revision++;
      } catch (_) {
        failure = '虚拟钱包未能保存，请重试。';
        error = failure;
      }
      notifyListeners();
    });
    await _writes;
    return failure;
  }

  /// One durable write covers balance, transaction state, receipt and replay key.
  /// This operates only on the fictional role wallet; no payment network exists.
  Future<String?> interact({
    required String requestId,
    required String operation,
    required String chatId,
    required String roleId,
    String roleName = '',
    String? transactionId,
    String kind = 'transfer',
    int cents = 0,
    String note = '',
    bool incoming = false,
    String cover = 'classic',
  }) async {
    String? failure;
    _writes = _writes.then((_) async {
      if (!_healthy) {
        failure = error;
        return;
      }
      if (_requests.contains(requestId)) return;
      if (requestId.length < 8 ||
          requestId.length > 100 ||
          chatId.isEmpty ||
          roleId.isEmpty ||
          note.length > 100 ||
          !['create', 'receive', 'refund'].contains(operation)) {
        failure = '虚拟交易信息不正确。';
        return;
      }
      final transactions = _transactions
          .map((t) => Map<String, dynamic>.from(t))
          .toList();
      final now = DateTime.now().toIso8601String();
      Map<String, dynamic>? target;
      var delta = 0;
      if (operation == 'create') {
        if (transactions.any((t) => t['id'] == requestId)) return;
        if (transactions.length >= 500 ||
            cents <= 0 ||
            cents > maxBalance ||
            !['transfer', 'redpacket', 'gift'].contains(kind)) {
          failure = '请填写有效的虚拟金额。';
          return;
        }
        target = {
          'id': requestId,
          'chatId': chatId,
          'roleId': roleId,
          'roleName': roleName,
          'kind': kind,
          'cents': cents,
          'note': note,
          'incoming': incoming,
          'cover': ['classic', 'spring', 'blue'].contains(cover)
              ? cover
              : 'classic',
          'state': 'pending',
          'created': now,
        };
        transactions.insert(0, target);
        if (!incoming) delta = -cents;
      } else {
        target = transactions
            .where(
              (t) =>
                  t['id'] == transactionId &&
                  t['chatId'] == chatId &&
                  t['roleId'] == roleId,
            )
            .firstOrNull;
        if (target == null) {
          failure = '这笔虚拟交易不属于当前对话。';
          return;
        }
        if (target['state'] != 'pending') return;
        target['state'] = operation == 'receive' ? 'received' : 'refunded';
        target['resolved'] = now;
        if ((operation == 'receive' && target['incoming'] == true) ||
            (operation == 'refund' && target['incoming'] != true))
          delta = target['cents'] as int;
      }
      final next = balance + delta;
      if (next < 0) {
        failure = '虚拟零钱余额不足。';
        return;
      }
      if (next > maxBalance) {
        failure = '超出虚拟钱包金额上限。';
        return;
      }
      final requests = [requestId, ..._requests].take(200).toList();
      final entries = [
        if (delta != 0)
          {
            'id': requestId,
            'kind': operation == 'create' ? target['kind'] : operation,
            'cents': delta,
            'balanceAfter': next,
            'roleId': roleId,
            'roleName': roleName,
            'note': target['note'],
            'created': now,
            'transactionId': target['id'],
          },
        ..._entries,
      ].take(100).toList();
      try {
        if (!await (await SharedPreferences.getInstance()).setString(
          storageKey,
          jsonEncode({
            'id': id,
            'balance': next,
            'entries': entries,
            'requests': requests,
            'transactions': transactions,
          }),
        ))
          throw StateError('not saved');
        balance = next;
        _entries = entries;
        _requests = requests;
        _transactions = transactions;
        error = null;
        revision++;
      } catch (_) {
        failure = '虚拟交易未能保存，请重试。';
        error = failure;
      }
      notifyListeners();
    });
    await _writes;
    return failure;
  }
}

final virtualWallet = VirtualWallet();

import 'package:flutter/material.dart';
import 'native_social_portrait.dart';
import 'chat_controls.dart';
import 'native_social_icons.dart';
import 'state.dart';
import 'ui_plugins.dart';
import 'virtual_wallet.dart';
import 'widgets.dart';

Future<void> showNativeSocialFinance(
  BuildContext context, {
  required ChatUiMode mode,
  required String kind,
  bool incoming = false,
  required VoidCallback onCreated,
  DemoStore? store,
  int? giftCents,
  String? giftName,
  ValueChanged<String>? navigate,
  ValueChanged<String>? go,
}) async {
  final data = store ?? demo,
      chat = (store ?? demo).conversations[(store ?? demo).conversation];
  final role = data.personas
      .where((role) => role.id == chat.personaId)
      .firstOrNull;
  if (role == null ||
      chat.groupMembers.isNotEmpty ||
      !const {'redpacket', 'transfer', 'gift'}.contains(kind)) {
    toast(context, '请先选择一个有效的角色独立对话。');
    return;
  }
  final red = kind == 'redpacket',
      accent = Color(
        kind == 'redpacket'
            ? 0xffdf6952
            : mode == ChatUiMode.qq
            ? 0xff009dff
            : 0xff07c160,
      );
  final amount = TextEditingController(
    text: giftCents == null ? '' : (giftCents / 100).toStringAsFixed(2),
  );
  final note = TextEditingController(text: giftName ?? '');
  var busy = false, cover = 'classic';
  String? error;
  final created = await Navigator.of(context).push<bool>(
    MaterialPageRoute(
      builder: (page) => StatefulBuilder(
        builder: (page, change) {
          void key(String value) {
            if (giftCents != null || busy) return;
            var text = amount.text;
            if (value == 'back')
              text = text.isEmpty ? text : text.substring(0, text.length - 1);
            else if (value == '.') {
              if (text.contains('.')) return;
              text = text.isEmpty ? '0.' : '$text.';
            } else {
              if (text == '0') text = '';
              text += value;
            }
            if (text.length > 9 ||
                (text.contains('.') && text.split('.').last.length > 2))
              return;
            change(() => amount.text = text);
          }

          Future<void> submit() async {
            if (busy) return;
            if (!identical(chat, data.conversations[data.conversation]) ||
                chat.personaId != role.id ||
                chat.groupMembers.isNotEmpty) {
              change(() => error = '对话已切换，请返回后重新操作。');
              return;
            }
            final cents = ((double.tryParse(amount.text) ?? 0) * 100).round();
            if (cents <= 0 || cents > VirtualWallet.maxBalance) {
              change(() => error = '请填写有效的虚拟金额。');
              return;
            }
            change(() {
              busy = true;
              error = null;
            });
            final failure = await virtualWallet.interact(
              requestId:
                  'native-finance-${DateTime.now().microsecondsSinceEpoch}',
              operation: 'create',
              chatId: chat.id,
              roleId: role.id,
              roleName: role.name,
              kind: kind,
              incoming: incoming,
              cents: cents,
              note: note.text,
              cover: cover,
            );
            if (failure == null) {
              chat.placeholder = false;
              data.changed();
              await data.saveChats();
              if (page.mounted) Navigator.pop(page, true);
            } else if (page.mounted) {
              change(() {
                busy = false;
                error = failure;
              });
            }
          }

          return Scaffold(
            backgroundColor: const Color(0xffededed),
            appBar: AppBar(
              actions: [
                IconButton(
                  tooltip: '更多',
                  onPressed: busy
                      ? null
                      : () => _socialFinanceMore(
                          page,
                          mode: mode,
                          navigate: navigate,
                          go: go,
                        ),
                  icon: const NativeSocialIcon('more'),
                ),
              ],
              toolbarHeight: 54,
              backgroundColor: const Color(0xffededed),
              surfaceTintColor: Colors.transparent,
              elevation: 0,
              leading: IconButton(
                tooltip: '返回',
                onPressed: busy ? null : () => Navigator.pop(page),
                icon: const NativeSocialIcon('chevron-left'),
              ),
              centerTitle: true,
              title: Text(
                red
                    ? incoming
                          ? '模拟角色发红包'
                          : '发红包'
                    : kind == 'gift'
                    ? '赠送礼物'
                    : incoming
                    ? '模拟角色转账'
                    : '转账',
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            body: SafeArea(
              top: false,
              child: Column(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
                      child: Column(
                        children: [
                          if (!red)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          '${incoming ? '来自' : '转账给'} ${role.name}',
                                          style: const TextStyle(fontSize: 16),
                                        ),
                                        const SizedBox(height: 7),
                                        const Text(
                                          '角色互动',
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: Color(0xff999999),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  NativeSocialPortrait(
                                    mode: mode,
                                    persona: role,
                                    size: 45,
                                    borderRadius: 5,
                                  ),
                                ],
                              ),
                            ),
                          Container(
                            padding: const EdgeInsets.all(18),
                            color: Colors.white,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  red
                                      ? '金额'
                                      : kind == 'gift'
                                      ? '礼物金额'
                                      : '转账金额',
                                  style: const TextStyle(fontSize: 16),
                                ),
                                const SizedBox(height: 12),
                                TextField(
                                  key: const ValueKey('social-finance-amount'),
                                  controller: amount,
                                  readOnly: true,
                                  showCursor: giftCents == null,
                                  style: const TextStyle(
                                    fontSize: 38,
                                    color: Color(0xff191919),
                                  ),
                                  decoration: const InputDecoration(
                                    prefixText: '¥ ',
                                    hintText: '0.00',
                                    border: InputBorder.none,
                                    isDense: true,
                                  ),
                                ),
                                if (!red)
                                  TextField(
                                    controller: note,
                                    maxLength: 100,
                                    decoration: const InputDecoration(
                                      hintText: '添加转账说明',
                                      counterText: '',
                                      border: InputBorder.none,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          if (red) ...[
                            const SizedBox(height: 12),
                            Container(
                              color: Colors.white,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 18,
                              ),
                              child: TextField(
                                controller: note,
                                maxLength: 100,
                                decoration: const InputDecoration(
                                  hintText: '恭喜发财，大吉大利',
                                  counterText: '',
                                  border: InputBorder.none,
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            Container(
                              color: Colors.white,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 18,
                              ),
                              child: Row(
                                children: [
                                  const Expanded(child: Text('红包封面')),
                                  DropdownButton<String>(
                                    value: cover,
                                    underline: const SizedBox(),
                                    items: const [
                                      DropdownMenuItem(
                                        value: 'classic',
                                        child: Text('经典红包'),
                                      ),
                                      DropdownMenuItem(
                                        value: 'spring',
                                        child: Text('春日祝福'),
                                      ),
                                      DropdownMenuItem(
                                        value: 'blue',
                                        child: Text('星空心意'),
                                      ),
                                    ],
                                    onChanged: busy
                                        ? null
                                        : (value) =>
                                              change(() => cover = value!),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 24),
                            Text(
                              '¥ ${(double.tryParse(amount.text) ?? 0).toStringAsFixed(2)}',
                              style: const TextStyle(fontSize: 38),
                            ),
                          ],
                          const SizedBox(height: 22),
                          const Text(
                            '角色互动 · 虚拟资金，仅保存在此设备',
                            style: TextStyle(
                              fontSize: 12,
                              color: Color(0xff999999),
                            ),
                          ),
                          if (error != null)
                            Padding(
                              padding: const EdgeInsets.all(12),
                              child: Text(
                                error!,
                                style: const TextStyle(
                                  color: Color(0xffd94c45),
                                  fontSize: 13,
                                ),
                              ),
                            ),
                          const SizedBox(height: 15),
                          SizedBox(
                            width: double.infinity,
                            height: 45,
                            child: FilledButton(
                              style: FilledButton.styleFrom(
                                backgroundColor: accent,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(4),
                                ),
                              ),
                              onPressed: busy ? null : submit,
                              child: Text(
                                busy
                                    ? '保存中…'
                                    : red
                                    ? '塞钱进红包'
                                    : kind == 'gift'
                                    ? '赠送'
                                    : '转账',
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (giftCents == null)
                    Container(
                      color: const Color(0xffd7d9df),
                      child: GridView(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 3,
                              mainAxisExtent: 54,
                              mainAxisSpacing: 1,
                              crossAxisSpacing: 1,
                            ),
                        children: [
                          for (final value in [
                            '1',
                            '2',
                            '3',
                            '4',
                            '5',
                            '6',
                            '7',
                            '8',
                            '9',
                            '.',
                            '0',
                            'back',
                          ])
                            InkWell(
                              onTap: busy ? null : () => key(value),
                              child: Container(
                                color: value == 'back' || value == '.'
                                    ? const Color(0xffe8e9ed)
                                    : Colors.white,
                                alignment: Alignment.center,
                                child: value == 'back'
                                    ? const Text(
                                        '⌫',
                                        style: TextStyle(fontSize: 25),
                                      )
                                    : Text(
                                        value,
                                        style: const TextStyle(
                                          fontSize: 25,
                                          color: Color(0xff191919),
                                        ),
                                      ),
                              ),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    ),
  );
  await Future<void>.delayed(const Duration(milliseconds: 250));
  amount.dispose();
  note.dispose();
  if (created == true) onCreated();
}

Future<void> showNativeSocialReceipt(
  BuildContext context,
  Map<String, dynamic> transaction, {
  required ChatUiMode mode,
  DemoStore? store,
  ValueChanged<String>? navigate,
  ValueChanged<String>? go,
}) async {
  final data = store ?? demo;
  final details = ValueNotifier(false);
  final role = data.personas
      .where((role) => role.id == transaction['roleId'])
      .firstOrNull;
  final red = transaction['kind'] == 'redpacket';
  await Navigator.of(context).push(
    MaterialPageRoute(
      builder: (page) => AnimatedBuilder(
        animation: Listenable.merge([virtualWallet, details]),
        builder: (page, _) {
          final current = (virtualWallet.snapshot()['transactions'] as List)
              .whereType<Map>()
              .where(
                (t) =>
                    t['id'] == transaction['id'] &&
                    t['chatId'] == transaction['chatId'] &&
                    t['roleId'] == transaction['roleId'],
              )
              .firstOrNull;
          if (current == null)
            return Scaffold(
              appBar: AppBar(title: const Text('记录已不存在')),
              body: const SizedBox(),
            );
          final state = current['state'],
              incoming = current['incoming'] == true;
          Future<void> act(String operation) async {
            final error = await virtualWallet.interact(
              requestId:
                  'native-receipt-${DateTime.now().microsecondsSinceEpoch}',
              operation: operation,
              transactionId: current['id'],
              chatId: current['chatId'],
              roleId: current['roleId'],
              roleName: current['roleName'] ?? '',
            );
            if (error != null && page.mounted) toast(page, error);
          }

          if (red && incoming && state == 'pending' && !details.value) {
            final cover = current['cover'];
            final colors = cover == 'blue'
                ? [const Color(0xff476fb0), const Color(0xff263d79)]
                : cover == 'spring'
                ? [const Color(0xffe68483), const Color(0xffcb585d)]
                : [const Color(0xffe16a53), const Color(0xffd95946)];
            return Scaffold(
              backgroundColor: Colors.black54,
              body: SafeArea(
                child: Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(25),
                    child: Container(
                      width: 310,
                      constraints: const BoxConstraints(minHeight: 395),
                      padding: const EdgeInsets.fromLTRB(20, 45, 20, 24),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: colors,
                        ),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Stack(
                        children: [
                          Positioned(
                            left: -10,
                            top: -35,
                            child: IconButton(
                              tooltip: '返回',
                              onPressed: () => Navigator.pop(page),
                              icon: const NativeSocialIcon(
                                'close',
                                size: 22,
                                color: Color(0xffedb18b),
                              ),
                            ),
                          ),
                          Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (role != null)
                                NativeSocialPortrait(
                                  mode: mode,
                                  persona: role,
                                  size: 43,
                                  borderRadius: 7,
                                ),
                              const SizedBox(height: 12),
                              Text(
                                '${current['roleName'] ?? ''}的红包',
                                style: const TextStyle(
                                  fontSize: 14,
                                  color: Color(0xffedd5a1),
                                ),
                              ),
                              const SizedBox(height: 30),
                              Text(
                                current['note']?.toString().isNotEmpty == true
                                    ? current['note']
                                    : '恭喜发财，大吉大利',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontSize: 23,
                                  height: 1.6,
                                  color: Color(0xffedd5a1),
                                ),
                              ),
                              const SizedBox(height: 40),
                              SizedBox(
                                width: 84,
                                height: 84,
                                child: FilledButton(
                                  style: FilledButton.styleFrom(
                                    padding: EdgeInsets.zero,
                                    backgroundColor: const Color(0xffeacb8c),
                                    foregroundColor: const Color(0xff725030),
                                    shape: const CircleBorder(),
                                  ),
                                  onPressed: () => act('receive'),
                                  child: const Text(
                                    '开',
                                    style: TextStyle(fontSize: 33),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 30),
                              TextButton(
                                onPressed: () => details.value = true,
                                child: const Text(
                                  '查看领取详情',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Color(0xffedc38c),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          }
          return Scaffold(
            backgroundColor: red
                ? const Color(0xfff9f1e6)
                : const Color(0xffededed),
            appBar: AppBar(
              actions: [
                IconButton(
                  tooltip: '更多',
                  onPressed: () => _socialFinanceMore(
                    page,
                    mode: mode,
                    navigate: navigate,
                    go: go,
                    transaction: Map<String, dynamic>.from(current),
                  ),
                  icon: const NativeSocialIcon('more'),
                ),
              ],
              toolbarHeight: 54,
              backgroundColor: Colors.transparent,
              surfaceTintColor: Colors.transparent,
              elevation: 0,
              leading: IconButton(
                tooltip: '返回',
                onPressed: () => Navigator.pop(page),
                icon: const NativeSocialIcon('chevron-left'),
              ),
              title: Text(
                red
                    ? '红包详情'
                    : current['kind'] == 'gift'
                    ? '礼物详情'
                    : '转账详情',
                style: const TextStyle(fontSize: 17),
              ),
              centerTitle: true,
            ),
            body: SafeArea(
              top: false,
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    const SizedBox(height: 40),
                    CircleAvatar(
                      radius: 35,
                      backgroundColor: red
                          ? const Color(0xffdf6952)
                          : const Color(0xfff5a142),
                      child: NativeSocialIcon(
                        red ? 'envelope' : 'transfer',
                        size: 38,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 28),
                    Text(
                      state == 'received'
                          ? red
                                ? '已领取'
                                : '已收款'
                          : state == 'refunded'
                          ? '已退回'
                          : red
                          ? '待领取'
                          : '待收款',
                      style: const TextStyle(fontSize: 21),
                    ),
                    const SizedBox(height: 22),
                    Text(
                      '¥${((current['cents'] as int) / 100).toStringAsFixed(2)}',
                      style: const TextStyle(
                        fontSize: 43,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      current['note']?.toString() ?? '',
                      style: const TextStyle(fontSize: 15),
                    ),
                    const SizedBox(height: 30),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (role != null) ...[
                          NativeSocialPortrait(
                            mode: mode,
                            persona: role,
                            size: 27,
                            borderRadius: 5,
                          ),
                          const SizedBox(width: 9),
                        ],
                        Text(
                          '${incoming ? '来自 ' : '转账给 '}${current['roleName'] ?? ''}',
                          style: const TextStyle(
                            fontSize: 14,
                            color: Color(0xff777777),
                          ),
                        ),
                      ],
                    ),
                    if (state == 'pending' && incoming) ...[
                      const SizedBox(height: 30),
                      FilledButton(
                        onPressed: () => act('receive'),
                        child: Text(red ? '开红包' : '确认收款'),
                      ),
                      TextButton(
                        onPressed: () => act('refund'),
                        child: const Text('立即退还'),
                      ),
                    ],
                    if (state == 'pending' && !incoming)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 25),
                        child: Text(
                          '等待对方${red ? '领取' : '确认收款'}',
                          style: const TextStyle(
                            fontSize: 14,
                            color: Color(0xff888888),
                          ),
                        ),
                      ),
                    const SizedBox(height: 24),
                    Text(
                      (current['created'] as String)
                          .replaceFirst('T', ' ')
                          .substring(0, 19),
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xffbbbbbb),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      '角色互动 · 虚拟资金，仅保存在此设备',
                      style: TextStyle(fontSize: 11, color: Color(0xff999999)),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    ),
  );
  details.dispose();
}

Future<void> _socialFinanceMore(
  BuildContext page, {
  required ChatUiMode mode,
  ValueChanged<String>? navigate,
  ValueChanged<String>? go,
  Map<String, dynamic>? transaction,
}) async {
  final outgoingPending =
      transaction?['state'] == 'pending' && transaction?['incoming'] != true;
  final choice = await Navigator.of(page).push<String>(
    MaterialPageRoute(
      builder: (more) => Scaffold(
        backgroundColor: const Color(0xffededed),
        appBar: AppBar(
          toolbarHeight: 54,
          backgroundColor: const Color(0xffededed),
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          centerTitle: true,
          title: const Text('更多', style: TextStyle(fontSize: 17)),
          leading: IconButton(
            tooltip: '返回',
            onPressed: () => Navigator.pop(more),
            icon: const NativeSocialIcon('chevron-left'),
          ),
        ),
        body: SafeArea(
          top: false,
          child: ListView(
            children: [
              for (final item in <(String, String, String)>[
                if (outgoingPending) ...[
                  (
                    'receive',
                    transaction!['kind'] == 'redpacket' ? '模拟角色领取' : '模拟角色收款',
                    'check',
                  ),
                  ('refund', '撤回虚拟资金', 'transfer'),
                ],
                ('wallet', '钱包', 'wallet'),
                ('models', '选择模型', 'sparkles'),
                ('settings', '设置', 'settings'),
              ])
                Container(
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    border: Border(
                      bottom: BorderSide(color: Color(0xffeeeeee), width: .5),
                    ),
                  ),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 8,
                    ),
                    leading: NativeSocialIcon(item.$3, size: 24),
                    title: Text(item.$2, style: const TextStyle(fontSize: 16)),
                    onTap: () => Navigator.pop(more, item.$1),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
  if (choice == null || !page.mounted) return;
  if (choice == 'receive' || choice == 'refund') {
    final error = await virtualWallet.interact(
      requestId: 'native-more-${DateTime.now().microsecondsSinceEpoch}',
      operation: choice,
      transactionId: transaction!['id'],
      chatId: transaction['chatId'],
      roleId: transaction['roleId'],
      roleName: transaction['roleName'] ?? '',
    );
    if (error != null && page.mounted) toast(page, error);
  } else if (choice == 'models') {
    await showChatModelPicker(page);
  } else if (choice == 'wallet') {
    if (navigate == null) {
      toast(page, '请返回主菜单打开钱包。');
      return;
    }
    Navigator.pop(page);
    navigate('wallet');
  } else if (choice == 'settings') {
    if (go != null) {
      Navigator.pop(page);
      go('/settings');
    } else {
      Navigator.of(page).pushNamed('/settings');
    }
  }
}

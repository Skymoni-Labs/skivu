import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'brand.dart';
import 'native_login_form.dart';
import 'account_beta_page.dart';
import 'relay_account.dart';
import 'state.dart';
import 'widgets.dart';

Future<void> pickRelayModel(BuildContext context) async {
  final selected = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => const _AccountModels(),
  );
  if (selected == null) return;
  try {
    await relayAccount.selectModel(selected);
    demo.useBeta = false;
    demo.useAccount = true;
    demo.changed();
    await demo.saveChats();
  } catch (_) {
    if (context.mounted) toast(context, '模型选择未保存，请重试');
  }
}

class RelayAccountPage extends StatefulWidget {
  const RelayAccountPage({super.key, required this.go});
  final ValueChanged<String> go;
  @override
  State<RelayAccountPage> createState() => _RelayAccountPageState();
}

class _RelayAccountPageState extends State<RelayAccountPage>
    with WidgetsBindingObserver {
  Timer? timer;
  bool active = true;
  Future<void> login() async {
    demo.useAccount = true;
    demo.useBeta = false;
    demo.changed();
    await demo.saveChats();
    await relayAccount.beginAuthorization();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    relayAccount.addListener(changed);
    if (relayAccount.signedIn) unawaited(relayAccount.refresh());
    schedule();
  }

  void changed() {
    if (!mounted) return;
    if (relayAccount.canChat && !relayAccount.authorizing) {
      // Login is enough to configure the service; no address or API Key form.
      if (!demo.useAccount || demo.useBeta) {
        demo.useAccount = true;
        demo.useBeta = false;
        demo.changed();
        unawaited(demo.saveChats());
      }
    }
    schedule();
    setState(() {});
  }

  void schedule() {
    timer?.cancel();
    if (active && relayAccount.authorizing)
      timer = Timer(Duration(seconds: relayAccount.pollInterval), () async {
        await relayAccount.pollAuthorization();
        if (mounted) schedule();
      });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    active = state == AppLifecycleState.resumed;
    if (active && relayAccount.authorizing)
      unawaited(relayAccount.pollAuthorization());
    schedule();
  }

  @override
  void dispose() {
    timer?.cancel();
    relayAccount.removeListener(changed);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  String money(dynamic quota) {
    final unit = relayAccount.quotaPerUnit;
    return quota is num && unit != null && unit > 0
        ? '${relayAccount.currency} ${(quota / unit).toStringAsFixed(4)}'
        : '—';
  }

  Future<void> logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('退出中转站账号？'),
        content: const Text('本机聊天记录和角色卡会保留，退出后可登录其他账号。正在生成的账号回复会停止。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (demo.useAccount && demo.streaming) demo.stop();
    await relayAccount.logout();
  }

  @override
  Widget build(BuildContext context) {
    final account = relayAccount;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Pane(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const BrandMark(size: 54),
              const SizedBox(height: 16),
              label(
                account.signedIn
                    ? (account.user?['display_name']?.toString() ?? '已登录')
                    : '一个账号，直接开始',
                size: 22,
                weight: FontWeight.w600,
              ),
              const SizedBox(height: 8),
              label(
                '登录 Skymoni 中转站，同步可用模型、钱包与订阅，无需逐个填写接口。',
                size: 12,
                color: muted,
              ),
              const SizedBox(height: 18),
              if (!account.supported)
                label('请在 Android 客户端中使用账号登录。网页预览仍可使用自定义模型连接。', size: 12)
              else if (account.authorizing) ...[
                label('请在中转站网页确认此设备的授权码', size: 12),
                const SizedBox(height: 12),
                SelectableText(
                  account.userCode ?? '',
                  style: const TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 3,
                  ),
                ),
                TextButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(
                      ClipboardData(text: account.userCode ?? ''),
                    );
                    if (context.mounted) toast(context, '授权码已复制');
                  },
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('复制完整授权码'),
                ),
                const SizedBox(height: 12),
                label(
                  '完成网页登录和授权后返回 App，会自动同步。请核对网页与此处的授权码一致。',
                  size: 12,
                  color: muted,
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  children: [
                    FilledButton(
                      onPressed: account.busy
                          ? null
                          : account.reopenAuthorization,
                      child: const Text('返回授权网页'),
                    ),
                    TextButton(
                      onPressed: () async {
                        try {
                          await account.cancelAuthorization();
                        } catch (_) {
                          if (context.mounted) toast(context, '取消未完成，请重试');
                        }
                      },
                      child: const Text('取消登录'),
                    ),
                  ],
                ),
              ] else if (!account.signedIn)
                NativeLoginForm(browserLogin: login)
              else ...[
                label(
                  '@${account.user?['username'] ?? ''}',
                  size: 12,
                  color: muted,
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: account.canChat
                          ? () => widget.go('/chat')
                          : null,
                      icon: const Icon(Icons.chat_bubble_outline),
                      label: const Text('开始聊天'),
                    ),
                    OutlinedButton.icon(
                      onPressed: account.busy ? null : account.refresh,
                      icon: const Icon(Icons.refresh),
                      label: const Text('同步额度'),
                    ),
                    TextButton.icon(
                      onPressed: account.loggingOut ? null : logout,
                      icon: const Icon(Icons.logout, size: 18),
                      label: const Text('退出账号'),
                    ),
                  ],
                ),
              ],
              if (account.busy)
                const Padding(
                  padding: EdgeInsets.only(top: 16),
                  child: LinearProgressIndicator(),
                ),
              if (account.error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: Text(
                    account.error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                      fontSize: 12,
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (account.signedIn) ...[
          const SizedBox(height: 16),
          AccountBetaPage(go: widget.go),
          const SizedBox(height: 16),
          Pane(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                label('中转钱包', size: 13, color: muted),
                const SizedBox(height: 10),
                label(
                  money(account.wallet?['balance']),
                  size: 27,
                  weight: FontWeight.w600,
                ),
                const SizedBox(height: 10),
                label(
                  '累计用量 ${money(account.wallet?['used'])}',
                  size: 12,
                  color: muted,
                ),
                label(
                  '请求次数 ${account.wallet?['request_count'] ?? '—'}',
                  size: 12,
                  color: muted,
                ),
                const SizedBox(height: 12),
                label('钱包与订阅分别展示，实际扣费顺序沿用中转站的账户设置。', size: 11, color: muted),
              ],
            ),
          ),
          for (final subscription in account.subscriptions) ...[
            const SizedBox(height: 12),
            Pane(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  label(
                    '订阅 #${subscription['plan_id'] ?? subscription['id']}',
                    weight: FontWeight.w600,
                  ),
                  const SizedBox(height: 8),
                  label(
                    subscription['unlimited'] == true
                        ? '用量不限额'
                        : '剩余 ${money(subscription['remaining'])}',
                    size: 17,
                  ),
                  label(
                    '已用 ${money(subscription['used'])}',
                    size: 12,
                    color: muted,
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 16),
          Pane(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                label('当前模型', size: 12, color: muted),
                const SizedBox(height: 8),
                Text(
                  account.activeModel ?? '暂无可用模型',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                label(
                  '${account.models.length} 个模型 · 按账号权限自动同步',
                  size: 11,
                  color: muted,
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: demo.streaming || account.models.isEmpty
                      ? null
                      : () => pickRelayModel(context),
                  icon: const Icon(Icons.tune),
                  label: const Text('选择模型'),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 18),
        label(
          '账号信息通过加密连接提交给 skymoni.com，App 不保存密码；登录会话可在站点撤销。',
          size: 11,
          color: muted,
        ),
      ],
    );
  }
}

class _AccountModels extends StatefulWidget {
  const _AccountModels();
  @override
  State<_AccountModels> createState() => _AccountModelsState();
}

class _AccountModelsState extends State<_AccountModels> {
  String query = '';
  @override
  Widget build(BuildContext context) {
    final models = relayAccount.models
        .where((m) => m.toLowerCase().contains(query.toLowerCase()))
        .toList();
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * .75,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(20),
            child: TextField(
              decoration: const InputDecoration(
                labelText: '搜索可用模型',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (value) => setState(() => query = value),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: models.length,
              itemBuilder: (context, index) => ListTile(
                title: Text(
                  models[index],
                  style: const TextStyle(fontSize: 13),
                ),
                trailing: models[index] == relayAccount.activeModel
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => Navigator.pop(context, models[index]),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

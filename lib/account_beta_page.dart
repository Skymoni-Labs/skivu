import 'dart:async';
import 'package:flutter/material.dart';
import 'relay_account.dart';
import 'state.dart';
import 'widgets.dart';

class AccountBetaPage extends StatefulWidget {
  const AccountBetaPage({super.key, required this.go});
  final ValueChanged<String> go;
  @override
  State<AccountBetaPage> createState() => _AccountBetaPageState();
}

class _AccountBetaPageState extends State<AccountBetaPage> {
  @override
  void initState() {
    super.initState();
    if (relayAccount.signedIn) unawaited(relayAccount.refresh());
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: relayAccount,
    builder: (context, _) {
      final a = relayAccount;
      final status = a.betaAccount['status'];
      final title = switch (status) {
        'approved' => '内测已开通',
        'pending' => '申请审核中',
        'suspended' || 'disabled' => '内测已暂停',
        'rejected' => '申请未通过',
        _ => a.signedIn ? '尚未开通内测' : '登录后查看内测计划',
      };
      final unit = a.quotaPerUnit;
      String money(dynamic n) => n is num && unit != null && unit > 0
          ? '${a.currency} ${(n / unit).toStringAsFixed(4)}'
          : '—';
      return Pane(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.science_outlined, size: 36, color: ink),
            const SizedBox(height: 14),
            label(title, size: 23, weight: FontWeight.w600),
            const SizedBox(height: 10),
            label(
              a.signedIn ? a.betaMessage : '使用同一个中转站账号即可同步申请结果与额度。',
              size: 13,
            ),
            if (a.signedIn) ...[
              const SizedBox(height: 20),
              label('可用内测额度', size: 12),
              label(
                money(a.betaAccount['balance']),
                size: 26,
                weight: FontWeight.w600,
              ),
              const SizedBox(height: 8),
              label(
                '已用 ${money(a.betaAccount['used'])} · 预留 ${money(a.betaAccount['reserved'])}',
                size: 12,
              ),
            ],
            const SizedBox(height: 18),
            label('申请通过后，资格和内测额度由管理员管理。内测额度与站内钱包分别计费，不会在不足时自动扣站内钱包。', size: 12),
            const SizedBox(height: 20),
            if (!a.signedIn)
              FilledButton(
                onPressed: () => widget.go('/settings/account'),
                child: const Text('登录中转站'),
              )
            else
              Wrap(
                spacing: 10,
                runSpacing: 8,
                children: [
                  if (a.canBetaChat)
                    FilledButton(
                      onPressed: demo.streaming || a.busy
                          ? null
                          : () async {
                              await a.selectFunding('beta');
                              if (!a.canChat) return;
                              demo.useAccount = true;
                              demo.useBeta = false;
                              demo.changed();
                              await demo.saveChats();
                              widget.go('/chat');
                            },
                      child: const Text('使用内测额度对话'),
                    ),
                  if (a.betaStatus?['account_approved'] != true)
                    FilledButton(
                      onPressed: () async {
                        try {
                          await a.platform.openWebsite(
                            'https://skymoni.com/creators',
                          );
                        } catch (_) {
                          if (context.mounted) toast(context, '申请页面未能打开，请稍后再试');
                        }
                      },
                      child: Text(
                        status == 'pending'
                            ? '查看申请进度'
                            : status == 'rejected'
                            ? '查看申请结果'
                            : '前往网页申请',
                      ),
                    ),
                  OutlinedButton(
                    onPressed: a.busy ? null : a.refresh,
                    child: const Text('刷新状态'),
                  ),
                ],
              ),
            if (a.busy)
              const Padding(
                padding: EdgeInsets.only(top: 16),
                child: LinearProgressIndicator(),
              ),
            if (a.error != null)
              Padding(
                padding: const EdgeInsets.only(top: 14),
                child: Text(a.error!),
              ),
          ],
        ),
      );
    },
  );
}

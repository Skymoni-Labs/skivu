import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'beta_access.dart';
import 'state.dart';
import 'widgets.dart';

class BetaSettingsPage extends StatefulWidget {
  const BetaSettingsPage({super.key, required this.go});
  final ValueChanged<String> go;
  @override
  State<BetaSettingsPage> createState() => _BetaSettingsPageState();
}

class _BetaSettingsPageState extends State<BetaSettingsPage>
    with WidgetsBindingObserver {
  Timer? poll;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (betaAccess.enrolled) unawaited(betaAccess.refresh());
    startPolling();
  }

  void startPolling() {
    poll?.cancel();
    poll = Timer.periodic(const Duration(seconds: 10), (_) {
      if (betaAccess.enrolled) betaAccess.refresh();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      startPolling();
      if (betaAccess.enrolled) betaAccess.refresh();
    } else {
      poll?.cancel();
    }
  }

  @override
  void dispose() {
    poll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  String amount(dynamic value) {
    final unit = betaAccess.quotaPerUnit;
    return value is num && unit != null && unit > 0
        ? (value / unit).toStringAsFixed(4)
        : '—';
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: betaAccess,
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Pane(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.science_outlined, color: green, size: 28),
                  const SizedBox(width: 12),
                  Expanded(
                    child: label(
                      'Skymoni 内测',
                      size: 20,
                      weight: FontWeight.w600,
                    ),
                  ),
                  const TinyTag('独立额度'),
                ],
              ),
              const SizedBox(height: 14),
              label(
                '在社区申请内测，审核通过后配对此设备。内测额度与普通 API 账户分别管理。',
                size: 12,
                color: muted,
              ),
              const SizedBox(height: 14),
              if (!betaAccess.supported)
                label('请使用 Android 客户端完成设备配对；网页预览不支持硬件设备证明。', size: 12)
              else if (!betaAccess.paired) ...[
                if (betaAccess.pairCode != null) ...[
                  label('设备配对码', size: 11, color: muted),
                  const SizedBox(height: 8),
                  SelectableText(
                    betaAccess.pairCode!,
                    style: const TextStyle(
                      fontSize: 22,
                      letterSpacing: 1.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  label(
                    '请在 skymoni.com 社区的内测申请卡中填写此码。配对码 5 分钟内有效。',
                    size: 11,
                    color: muted,
                  ),
                  TextButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(
                        ClipboardData(text: betaAccess.pairCode!),
                      );
                      if (context.mounted) toast(context, '配对码已复制');
                    },
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text('复制配对码'),
                  ),
                ],
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: betaAccess.busy ? null : betaAccess.enroll,
                  icon: const Icon(Icons.phonelink_lock, size: 18),
                  label: Text(betaAccess.enrolled ? '重新生成配对码' : '生成设备配对码'),
                ),
              ] else ...[
                Row(
                  children: [
                    Icon(Icons.check_circle_outline, color: green, size: 19),
                    const SizedBox(width: 8),
                    const Text('设备已配对'),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 22,
                  runSpacing: 12,
                  children: [
                    for (final item in [
                      ('内测额度', 'balance'),
                      ('暂占额度', 'reserved'),
                      ('已用额度', 'used'),
                    ])
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          label(item.$1, size: 10, color: muted),
                          label(
                            amount(betaAccess.account?[item.$2]),
                            size: 20,
                            weight: FontWeight.w600,
                          ),
                        ],
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                label(
                  betaAccess.account?['status'] == 'approved'
                      ? '内测资格已开通'
                      : '当前内测资格暂不可用，请在社区查看审核状态。',
                  size: 12,
                  color: muted,
                ),
              ],
              if (betaAccess.busy)
                const Padding(
                  padding: EdgeInsets.only(top: 14),
                  child: LinearProgressIndicator(minHeight: 2),
                ),
              if (betaAccess.error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: Text(
                    betaAccess.error!,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              if (betaAccess.enrolled)
                TextButton.icon(
                  onPressed: betaAccess.busy ? null : betaAccess.refresh,
                  icon: const Icon(Icons.refresh, size: 17),
                  label: const Text('刷新配对状态'),
                ),
            ],
          ),
        ),
        if (betaAccess.paired) ...[
          const SizedBox(height: 18),
          Pane(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                label('内测模型', size: 16, weight: FontWeight.w600),
                const SizedBox(height: 14),
                if (betaAccess.models.isEmpty)
                  label('暂未分配可用模型，请等待管理员配置。', size: 12, color: muted)
                else
                  DropdownButtonFormField<String>(
                    initialValue: betaAccess.activeModel,
                    key: ValueKey(betaAccess.activeModel),
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: '选择模型'),
                    items: betaAccess.models
                        .map(
                          (m) => DropdownMenuItem(
                            value: m,
                            child: Text(
                              m,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: demo.streaming
                        ? null
                        : (v) async {
                            try {
                              await betaAccess.selectModel(v!);
                            } catch (_) {
                              if (context.mounted)
                                toast(context, '模型选择未能保存，请重试');
                            }
                          },
                  ),
                const SizedBox(height: 18),
                FilledButton.icon(
                  onPressed: !betaAccess.canChat || demo.streaming
                      ? null
                      : () {
                          demo.useBeta = true;
                          demo.changed();
                          demo.saveChats();
                          widget.go('/chat');
                        },
                  icon: const Icon(Icons.chat_bubble_outline, size: 17),
                  label: const Text('使用内测模型聊天'),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 18),
        label(
          '设备凭据仅用于 skymoni.com 内测接口，不会发送给自定义 API 地址。硬件证明与正式签名由服务端核验；不符合条件时不会降低验证要求。',
          size: 11,
          color: muted,
        ),
      ],
    ),
  );
}

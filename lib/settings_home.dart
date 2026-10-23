import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'model_settings.dart';
import 'state.dart';
import 'widgets.dart';
import 'brand.dart';
import 'relay_account.dart';
import 'app_updates.dart';

class SettingsHome extends StatelessWidget {
  const SettingsHome({super.key, required this.go});
  final ValueChanged<String> go;

  Widget group(String title, List<(String, String, IconData, String)> rows) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 0, 8),
              child: label(title, size: 12, weight: FontWeight.w600),
            ),
            Pane(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
              child: Column(
                children: [
                  for (var i = 0; i < rows.length; i++) ...[
                    ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 3,
                      ),
                      minLeadingWidth: 32,
                      horizontalTitleGap: 12,
                      leading: Container(
                        width: 34,
                        height: 34,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: green.withValues(alpha: .08),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(rows[i].$3, size: 20, color: ink),
                      ),
                      title: Text(
                        rows[i].$1,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      subtitle: Text(
                        rows[i].$2,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11, height: 1.5),
                      ),
                      trailing: const Icon(Icons.chevron_right, size: 19),
                      onTap: () => go(rows[i].$4),
                    ),
                    if (i < rows.length - 1)
                      const Divider(height: 1, indent: 48),
                  ],
                ],
              ),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([modelSettings, relayAccount, appUpdates]),
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Pane(
          padding: const EdgeInsets.all(6),
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 10,
              vertical: 6,
            ),
            leading: const SizedBox(width: 44, height: 44, child: BrandMark()),
            title: Text(
              relayAccount.signedIn
                  ? (relayAccount.user?['display_name']?.toString() ?? '我的账号')
                  : '登录 Skymoni',
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              relayAccount.signedIn ? '模型、余额与内测计划' : '登录后同步模型和额度',
              style: const TextStyle(fontSize: 12),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => go('/settings/account'),
          ),
        ),
        const SizedBox(height: 24),
        group('连接与服务', [
          (
            '模型与服务',
            modelSettings.connections.isEmpty
                ? '接入自己的模型 API'
                : '${modelSettings.connections.length} 个自定义连接',
            Icons.hub_outlined,
            '/settings/models',
          ),
          ('语音与通话', '语音合成、音色、语速与试听', Icons.graphic_eq, '/settings/speech'),
          ('内测计划', '申请状态与专属额度', Icons.science_outlined, '/settings/beta'),
        ]),
        group('使用偏好', [
          ('界面模式', 'Skivu、微信与 QQ 模式', Icons.chat_bubble_outline, '/plugins'),
          ('社交与群聊', '朋友圈、空间与群聊默认规则', Icons.forum_outlined, '/settings/social'),
          (
            '外观与体验',
            '主题、壁纸、文字与玻璃材质',
            Icons.palette_outlined,
            '/settings/appearance',
          ),
          ('聊天记录', '本地保存、备份与清理', Icons.history_rounded, '/settings/data'),
          ('隐私与权限', '了解数据如何使用', Icons.shield_outlined, '/settings/permissions'),
        ]),
        group('应用', [
          (
            '检查更新',
            appUpdates.release == null
                ? 'Skivu $appVersion'
                : '发现新版本 ${appUpdates.release!.version}',
            Icons.system_update_outlined,
            '/settings/updates',
          ),
          ('关于 Skivu', '开源许可与应用信息', Icons.info_outline, '/settings/about'),
        ]),
        Center(child: label('Skivu $appVersion', size: 11)),
        const SizedBox(height: 12),
      ],
    ),
  );
}

class ChatDataSettings extends StatelessWidget {
  const ChatDataSettings({super.key});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Pane(
        child: Row(
          children: [
            Icon(Icons.history, color: green, size: 30),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  label(
                    '${demo.conversations.where((c) => c.messages.isNotEmpty).length} 段对话',
                    size: 20,
                    weight: FontWeight.w600,
                  ),
                  label('聊天记录保存在此设备', size: 12, color: muted),
                ],
              ),
            ),
          ],
        ),
      ),
      if (demo.storageError != null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Text(
            demo.storageError!,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.error,
            ),
          ),
        ),
      const SizedBox(height: 18),
      Pane(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Column(
          children: [
            SettingRow(
              '导出聊天备份',
              '包含会话与消息，不包含 API Key',
              icon: Icons.file_download_outlined,
              onTap: () async {
                await Clipboard.setData(
                  ClipboardData(text: demo.exportChats()),
                );
                if (context.mounted) toast(context, '聊天备份已复制，可粘贴到文件中保存');
              },
            ),
            const Divider(height: 1),
            SettingRow(
              '恢复聊天备份',
              '从此前导出的备份恢复',
              icon: Icons.restore_outlined,
              onTap: () => showDialog(
                context: context,
                builder: (_) => const _ImportChatsDialog(),
              ),
            ),
            const Divider(height: 1),
            SettingRow(
              '清空聊天记录',
              '删除此设备上的全部会话',
              icon: Icons.delete_outline,
              onTap: () async {
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (c) => AlertDialog(
                    title: const Text('清空全部聊天记录？'),
                    content: const Text('此操作无法撤销，建议先导出备份。模型连接和外观设置会保留。'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(c, false),
                        child: const Text('取消'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(c, true),
                        child: const Text('清空记录'),
                      ),
                    ],
                  ),
                );
                if (confirmed == true) {
                  try {
                    await demo.clearChats();
                    if (context.mounted) toast(context, '聊天记录已清空');
                  } catch (_) {
                    if (context.mounted) toast(context, '清空失败，原记录已保留');
                  }
                }
              },
            ),
          ],
        ),
      ),
      const SizedBox(height: 18),
      label(
        '发送消息时，当前对话内容与角色设定会发送至你选择的模型服务。记录不由 Skivu 上传同步；服务商的数据规则以其说明为准。',
        size: 11,
        color: muted,
      ),
    ],
  );
}

class _ImportChatsDialog extends StatefulWidget {
  const _ImportChatsDialog();
  @override
  State<_ImportChatsDialog> createState() => _ImportChatsDialogState();
}

class _ImportChatsDialogState extends State<_ImportChatsDialog> {
  final input = TextEditingController();
  String? error;
  bool busy = false;
  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('恢复聊天备份'),
    content: SizedBox(
      width: 400,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('恢复将替换当前聊天记录，请确认已备份。', style: TextStyle(fontSize: 12)),
          const SizedBox(height: 16),
          TextField(
            controller: input,
            minLines: 4,
            maxLines: 8,
            enabled: !busy,
            decoration: InputDecoration(
              hintText: '粘贴聊天备份内容',
              errorText: error,
              errorMaxLines: 3,
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: busy ? null : () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: busy
            ? null
            : () async {
                setState(() {
                  busy = true;
                  error = null;
                });
                try {
                  await demo.importChats(input.text);
                  if (context.mounted) Navigator.pop(context);
                } catch (_) {
                  if (mounted)
                    setState(() {
                      busy = false;
                      error = '无法恢复，请检查备份内容与设备存储。';
                    });
                }
              },
        child: Text(busy ? '正在恢复…' : '确认恢复'),
      ),
    ],
  );
}

class PrivacySettings extends StatelessWidget {
  const PrivacySettings({super.key});
  @override
  Widget build(BuildContext context) => Pane(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.shield_outlined, size: 32, color: green),
        const SizedBox(height: 16),
        label('连接由你选择，数据由你掌握', size: 18, weight: FontWeight.w600),
        const SizedBox(height: 14),
        label('聊天内容仅在发送时交给你配置的模型服务。API Key 单独加密保存在设备中，聊天备份不包含密钥。', size: 12),
        const SizedBox(height: 14),
        label(
          '选择自定义背景或字体时，系统会由你挑选文件。文字聊天无需麦克风、联系人或定位权限。语音通话会按需请求麦克风；系统识别可能联网，App 不保存录音文件。',
          size: 12,
        ),
        const SizedBox(height: 14),
        label(
          '浏览器预览使用独立于手机的本地存储；直接访问第三方 API 需要该服务允许浏览器跨域请求。',
          size: 11,
          color: muted,
        ),
      ],
    ),
  );
}

class SkivuAbout extends StatelessWidget {
  const SkivuAbout({super.key});
  @override
  Widget build(BuildContext context) => Pane(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const BrandMark(size: 72),
        const SizedBox(height: 18),
        label('Skivu', size: 32, weight: FontWeight.w600),
        label(appVersion, size: 12, color: muted),
        const SizedBox(height: 22),
        label('让每次对话，都有回应。', size: 14),
        const SizedBox(height: 24),
        SettingRow(
          '开源许可',
          '感谢每一位开源贡献者',
          icon: Icons.article_outlined,
          onTap: () => showLicensePage(
            context: context,
            applicationName: 'Skivu',
            applicationVersion: appVersion,
          ),
        ),
      ],
    ),
  );
}

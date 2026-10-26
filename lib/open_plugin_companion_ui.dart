// SPDX-License-Identifier: GPL-3.0-only
import 'package:flutter/material.dart';
import 'open_plugin.dart';
import 'open_plugin_companion.dart';
import 'open_plugin_external.dart';
import 'open_plugin_page.dart';
import 'state.dart';

final companionNavigator = GlobalKey<NavigatorState>();
VoidCallback? companionReturnToChat;
void configureCompanionUI() {
  companionExternal = (record, url, check) => openPluginExternal(
    {'url': url},
    check: check,
    confirm: (uri) async {
      final context = companionNavigator.currentContext;
      if (context == null || !context.mounted) return false;
      return await showDialog<bool>(
            context: context,
            builder: (c) => AlertDialog(
              title: const Text('打开外部软件或网页？'),
              content: Text(
                '${record.manifest.name}\n$uri\n\n交给系统处理，不表示已登录、发送或完成交易。',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(c, false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(c, true),
                  child: const Text('打开'),
                ),
              ],
            ),
          ) ??
          false;
    },
  );
}

Future<void> _bindRole(
  BuildContext context,
  String id,
  String roleId, {
  required bool enabled,
  bool chat = false,
  String scope = 'story',
}) async {
  try {
    await openPlugins.bindRole(
      id,
      roleId,
      enabled: enabled,
      chat: chat,
      scope: scope,
    );
  } catch (_) {
    if (context.mounted)
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('角色插件设置尚未保存，请重试。')));
  }
}

Future<void> showRoleCompanions(
  BuildContext context,
  Persona role,
) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  builder: (c) => SafeArea(
    child: AnimatedBuilder(
      animation: openPlugins,
      builder: (c, _) => SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '${role.name}的随身插件',
                style: Theme.of(c).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              const Text('为角色单独启用。查看时才打开页面；随聊更新仅在正常聊天时按需执行，退出App后不定时生成。'),
              for (final record in openPlugins.records.values.where(
                (r) => r.manifest.companion != null,
              )) ...[
                const Divider(),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(record.manifest.companion!['title']),
                  subtitle: Text(
                    !record.authorized
                        ? '请先在插件市场启用并授权'
                        : openPlugins.bindingFor(record.manifest.id, role.id) ==
                              null
                        ? '此角色尚未绑定'
                        : '${openPlugins.bindingFor(record.manifest.id, role.id)!['chat'] == true ? '随聊更新' : '仅手动使用'} · ${openPlugins.bindingFor(record.manifest.id, role.id)!['scope'] == 'story' ? '各故事独立' : '同角色共用'}',
                  ),
                  trailing: Switch(
                    value:
                        openPlugins.bindingFor(record.manifest.id, role.id) !=
                        null,
                    onChanged: !record.authorized
                        ? null
                        : (value) async {
                            await _bindRole(
                              c,
                              record.manifest.id,
                              role.id,
                              enabled: value,
                            );
                          },
                  ),
                ),
                if (record.authorized &&
                    openPlugins.bindingFor(record.manifest.id, role.id) !=
                        null) ...[
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('允许随正常聊天读写本机记录'),
                    subtitle: const Text(
                      '可随时关闭。一次聊天最多4次模型请求，可能增加额度消耗；外部操作另行确认。',
                    ),
                    value:
                        openPlugins.bindingFor(
                          record.manifest.id,
                          role.id,
                        )!['chat'] ==
                        true,
                    onChanged: (value) async {
                      final b = openPlugins.bindingFor(
                        record.manifest.id,
                        role.id,
                      )!;
                      await _bindRole(
                        c,
                        record.manifest.id,
                        role.id,
                        enabled: true,
                        chat: value,
                        scope: b['scope'],
                      );
                    },
                  ),
                  DropdownButtonFormField<String>(
                    isExpanded: true,
                    initialValue: openPlugins.bindingFor(
                      record.manifest.id,
                      role.id,
                    )!['scope'],
                    key: ValueKey(
                      '${record.manifest.id}:${openPlugins.bindingFor(record.manifest.id, role.id)!['scope']}:${openPlugins.roleBindingRevision}',
                    ),
                    decoration: const InputDecoration(labelText: '存档归属'),
                    items: const [
                      DropdownMenuItem(
                        value: 'story',
                        child: Text(
                          '各故事独立（每段聊天分别保存）',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      DropdownMenuItem(
                        value: 'role',
                        child: Text(
                          '同角色共用（可沿用已有角色存档）',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                    onChanged: (value) async {
                      if (value == null) return;
                      final b = openPlugins.bindingFor(
                        record.manifest.id,
                        role.id,
                      )!;
                      await _bindRole(
                        c,
                        record.manifest.id,
                        role.id,
                        enabled: true,
                        chat: b['chat'],
                        scope: value,
                      );
                    },
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      '切换只改变当前查看空间，不删除或合并旧记录。',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      Navigator.pop(c);
                      launchOpenPlugin(context, record, roleId: role.id);
                    },
                    child: Text('打开${record.manifest.companion!['title']}'),
                  ),
                ],
              ],
              if (!openPlugins.records.values.any(
                (r) => r.manifest.companion != null,
              ))
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('可先到插件市场安装支持角色绑定的插件。'),
                ),
              TextButton(
                onPressed: () => Navigator.pop(c),
                child: const Text('完成'),
              ),
            ],
          ),
        ),
      ),
    ),
  ),
);

class CompanionMessageCards extends StatelessWidget {
  const CompanionMessageCards({super.key, required this.message});
  final Message message;
  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (final card in message.pluginCards)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: OutlinedButton(
            onPressed: () {
              final record = openPlugins.records[card['pluginId']];
              final chat = demo.conversations
                  .where((c) => c.id == card['chatId'])
                  .firstOrNull;
              if (record == null ||
                  !record.authorized ||
                  chat == null ||
                  openPlugins.bindingFor(record.manifest.id, card['roleId']) ==
                      null) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('请先重新绑定或启用这个角色的插件。')),
                );
                return;
              }
              launchOpenPlugin(
                context,
                record,
                action: card['action'],
                payload: card['payload'] is Map
                    ? Map<String, dynamic>.from(card['payload'])
                    : {},
                roleId: card['roleId'],
                chatId: card['chatId'],
              );
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.open_in_new, size: 18),
                  const SizedBox(width: 9),
                  Flexible(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(card['title']),
                        Text(
                          card['summary'],
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
    ],
  );
}

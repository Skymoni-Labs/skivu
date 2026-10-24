import 'package:flutter/material.dart';
import 'appearance.dart';
import 'model_connection.dart';
import 'model_settings.dart';
import 'relay_account.dart';
import 'state.dart';
import 'widgets.dart';
import 'character_avatar.dart';

Future<void> showChatModelPicker(BuildContext context) async {
  String query = '';
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (sheet) => StatefulBuilder(
      builder: (sheet, change) => AnimatedBuilder(
        animation: relayAccount,
        builder: (_, _) => SizedBox(
          height: MediaQuery.sizeOf(sheet).height * .72,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                label('选择模型', size: 22, weight: FontWeight.w600),
                if (relayAccount.signedIn)
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final f in ['relay', 'beta'])
                        ChoiceChip(
                          label: Text(f == 'relay' ? '站内额度' : '内测额度'),
                          selected: relayAccount.funding == f,
                          onSelected: demo.streaming || relayAccount.busy
                              ? null
                              : (_) async {
                                  await relayAccount.selectFunding(f);
                                  if (sheet.mounted) change(() {});
                                },
                        ),
                    ],
                  ),
                const SizedBox(height: 10),
                TextField(
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: '搜索模型',
                  ),
                  onChanged: (v) =>
                      change(() => query = v.trim().toLowerCase()),
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: ListView(
                    children: [
                      if (!relayAccount.signedIn)
                        ListTile(
                          leading: const Icon(Icons.login),
                          title: const Text('登录中转站，同步可用模型'),
                          onTap: () {
                            Navigator.pop(sheet);
                            Navigator.of(
                              context,
                            ).pushReplacementNamed('/settings/account');
                          },
                        ),
                      if (relayAccount.busy) const LinearProgressIndicator(),
                      if (relayAccount.funding == 'beta' &&
                          relayAccount.signedIn &&
                          !relayAccount.canBetaChat)
                        ListTile(
                          title: const Text('内测计划暂不可用于对话'),
                          subtitle: Text(relayAccount.betaMessage),
                          onTap: () {
                            Navigator.pop(sheet);
                            Navigator.of(
                              context,
                            ).pushReplacementNamed('/settings/beta');
                          },
                        ),
                      for (final model in relayAccount.models.where(
                        (id) => id.toLowerCase().contains(query),
                      ))
                        ListTile(
                          title: Text(model, maxLines: 2),
                          subtitle: Text(
                            relayAccount.funding == 'beta'
                                ? 'Skymoni · 内测额度'
                                : 'Skymoni · 站内额度',
                          ),
                          trailing:
                              demo.useAccount &&
                                  relayAccount.activeModel == model
                              ? const Icon(Icons.check_circle_outline)
                              : null,
                          enabled:
                              !demo.streaming &&
                              !relayAccount.busy &&
                              (relayAccount.funding != 'beta' ||
                                  relayAccount.canBetaChat),
                          onTap: () async {
                            try {
                              await relayAccount.selectModel(model);
                              demo.useAccount = true;
                              demo.useBeta = false;
                              demo.changed();
                              await demo.saveChats();
                              if (sheet.mounted) Navigator.pop(sheet);
                            } catch (_) {
                              if (sheet.mounted) toast(sheet, '选择未保存，请重试');
                            }
                          },
                        ),
                      if (modelSettings.connections.isNotEmpty)
                        const ListTile(title: Text('我的其他连接')),
                      for (final profile in modelSettings.connections.where(
                        (p) => '${p.name} ${p.model}'.toLowerCase().contains(
                          query,
                        ),
                      ))
                        ListTile(
                          title: Text(profile.model),
                          subtitle: Text(profile.name),
                          enabled: !demo.streaming,
                          onTap: () async {
                            try {
                              await modelSettings.select(profile.id);
                              demo.useAccount = false;
                              demo.useBeta = false;
                              demo.changed();
                              await demo.saveChats();
                              if (sheet.mounted) Navigator.pop(sheet);
                            } catch (_) {
                              if (sheet.mounted) toast(sheet, '选择未保存，请重试');
                            }
                          },
                        ),
                      if (relayAccount.error != null)
                        ListTile(title: Text(relayAccount.error!)),
                      ListTile(
                        leading: const Icon(Icons.settings_outlined),
                        title: const Text('管理其他模型连接'),
                        onTap: () {
                          Navigator.pop(sheet);
                          Navigator.of(
                            context,
                          ).pushReplacementNamed('/settings/models');
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> editUserAvatar(BuildContext context) async {
  final action = await showModalBottomSheet<String>(
    context: context,
    useSafeArea: true,
    showDragHandle: true,
    builder: (sheet) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          title: const Text('从相册选择头像'),
          leading: const Icon(Icons.photo_library_outlined),
          onTap: () => Navigator.pop(sheet, 'choose'),
        ),
        if (demo.userAvatar != null)
          ListTile(
            title: const Text('恢复默认头像'),
            leading: const Icon(Icons.person_outline),
            onTap: () => Navigator.pop(sheet, 'reset'),
          ),
      ],
    ),
  );
  if (action == null) return;
  try {
    final bytes = action == 'reset'
        ? null
        : await pickCharacterAvatar(user: true);
    if (action != 'reset' && bytes == null) return;
    demo.userAvatar = bytes;
    demo.changed();
    await demo.saveChats();
    if (context.mounted) toast(context, demo.storageError ?? '头像已保存');
  } catch (_) {
    if (context.mounted) toast(context, '请选择 3MB 以内的图片，头像未更改。');
  }
}

Future<void> editUserCard(BuildContext context) async {
  final fields = {
    for (final key in ['称呼', '身份与背景', '性格与偏好', '与角色的关系', '交流边界'])
      key: TextEditingController(text: demo.userCard[key] ?? ''),
  };
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (sheet) => SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        22,
        0,
        22,
        MediaQuery.viewInsetsOf(sheet).bottom + 24,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          label('我的角色卡', size: 22, weight: FontWeight.w600),
          label('让对方了解你。保存后用于接下来发送的对话。', size: 12),
          AnimatedBuilder(
            animation: demo,
            builder: (context, _) => ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const UserAvatar(size: 48),
              title: const Text('我的头像'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => editUserAvatar(context),
            ),
          ),
          for (final e in fields.entries)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: TextField(
                controller: e.value,
                minLines: 1,
                maxLines: 4,
                maxLength: 4000,
                decoration: InputDecoration(labelText: e.key),
              ),
            ),
          FilledButton(
            onPressed: () async {
              demo.userCard = {
                ...demo.userCard,
                for (final e in fields.entries) e.key: e.value.text.trim(),
              };
              demo.changed();
              await demo.saveChats();
              if (sheet.mounted) Navigator.pop(sheet);
            },
            child: const Text('保存角色卡'),
          ),
        ],
      ),
    ),
  );
  // Bottom-sheet reverse transitions retain their fields for one more frame.
  await Future<void>.delayed(const Duration(milliseconds: 300));
  for (final field in fields.values) {
    field.dispose();
  }
}

Future<void> showChatControls(BuildContext context) async {
  final config = demo.activeConnection;
  double maximum = (config?.maxOutput ?? 2048).toDouble().clamp(128, 4096);
  bool streaming = config?.streaming ?? true;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (sheet) => StatefulBuilder(
      builder: (sheet, change) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(22, 0, 22, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            label('对话设置', size: 22, weight: FontWeight.w600),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('确认后再回复'),
              subtitle: const Text('先把短句暂存为多个气泡，确认发送后角色统一回复。'),
              value: demo.conversations[demo.conversation].confirmBeforeReply,
              onChanged: (v) {
                demo.conversations[demo.conversation].confirmBeforeReply = v;
                demo.changed();
                demo.saveChats();
                change(() {});
              },
            ),
            const SizedBox(height: 12),
            label('角色回复宽度', size: 13),
            Wrap(
              spacing: 8,
              children: [
                for (final entry in assistantBubbleLayouts.entries)
                  ChoiceChip(
                    key: ValueKey('chat-reply-layout-${entry.key}'),
                    label: Text(entry.value),
                    selected:
                        appearance.text('assistantBubbleLayout') == entry.key,
                    onSelected: (_) {
                      appearance.set('assistantBubbleLayout', entry.key);
                      appearance.save();
                      change(() {});
                    },
                  ),
              ],
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.face_outlined),
              title: const Text('编辑对话角色卡'),
              subtitle: Text(demo.role.name),
              onTap: () {
                Navigator.pop(sheet);
                demo.editCurrentRole();
                Navigator.of(context).pushReplacementNamed('/characters/edit');
              },
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.person_outline),
              title: const Text('我的角色卡'),
              onTap: () {
                Navigator.pop(sheet);
                editUserCard(context);
              },
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('显示思考过程'),
              value: appearance.flag('showThinking'),
              onChanged: (v) {
                appearance.set('showThinking', v);
                change(() {});
              },
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('显示底部统计'),
              value: appearance.flag('showUsage'),
              onChanged: (v) {
                appearance.set('showUsage', v);
                change(() {});
              },
            ),
            if (!demo.useAccount && !demo.useBeta)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.tune),
                title: const Text('高级模型参数'),
                subtitle: const Text('温度、上下文容量与等待时间'),
                onTap: () {
                  Navigator.pop(sheet);
                  Navigator.of(
                    context,
                  ).pushReplacementNamed('/settings/models');
                },
              ),
            const Divider(),
            label('最大回复 Token：${maximum.round()}', size: 14),
            Slider(
              value: maximum,
              min: 128,
              max: 4096,
              divisions: 31,
              onChanged: demo.streaming
                  ? null
                  : (v) => change(() => maximum = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('流式显示回复'),
              value: streaming,
              onChanged: demo.streaming
                  ? null
                  : (v) => change(() => streaming = v),
            ),
            FilledButton(
              onPressed: demo.streaming || config == null
                  ? null
                  : () async {
                      try {
                        if (demo.useAccount) {
                          await relayAccount.setGeneration(
                            maximum.round(),
                            streaming,
                          );
                        } else if (!demo.useBeta) {
                          final updated = ModelConnection.fromJson({
                            ...config.toJson(),
                            'maxOutput': maximum.round(),
                            'streaming': streaming,
                          });
                          await modelSettings.save(
                            updated,
                            await modelSettings.keyFor(config.id),
                          );
                        }
                        demo.changed();
                        if (sheet.mounted) Navigator.pop(sheet);
                      } catch (_) {
                        if (sheet.mounted) toast(sheet, '参数未保存，请重试');
                      }
                    },
              child: const Text('保存对话参数'),
            ),
          ],
        ),
      ),
    ),
  );
}

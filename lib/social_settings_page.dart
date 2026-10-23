import 'package:flutter/material.dart';
import 'social_settings.dart';
import 'social_activity.dart';
import 'state.dart';
import 'widgets.dart';

class SocialSettingsPage extends StatefulWidget {
  const SocialSettingsPage({super.key, this.settings});
  final SocialSettings? settings;
  @override
  State<SocialSettingsPage> createState() => _SocialSettingsPageState();
}

class _SocialSettingsPageState extends State<SocialSettingsPage> {
  late final settings = widget.settings ?? socialSettings;
  late Map<String, dynamic> draft = Map.of(settings.value.toJson());
  bool saving = false;
  String? feedback;
  Widget section(String title, List<Widget> children) => Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
          child: Text(
            title,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
        ),
        Pane(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Column(children: children),
        ),
      ],
    ),
  );
  Widget toggle(String key, String title, String subtitle) =>
      SwitchListTile.adaptive(
        contentPadding: EdgeInsets.zero,
        title: Text(title, style: const TextStyle(fontSize: 14)),
        subtitle: Text(
          subtitle,
          style: const TextStyle(fontSize: 12, height: 1.5),
        ),
        value: draft[key] == true,
        onChanged: saving ? null : (v) => setState(() => draft[key] = v),
      );
  Widget select(String key, String label, Map<Object, String> items) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: DropdownButtonFormField<Object>(
      initialValue: draft[key],
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: items.entries
          .map(
            (e) => DropdownMenuItem(
              value: e.key,
              child: Text(e.value, overflow: TextOverflow.ellipsis),
            ),
          )
          .toList(),
      onChanged: saving ? null : (v) => setState(() => draft[key] = v),
    ),
  );
  Widget roleList(String key) => Column(
    children: [
      if (demo.personas.isEmpty) const ListTile(title: Text('先在角色管理中添加角色')),
      for (final role in demo.personas)
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          controlAffinity: ListTileControlAffinity.leading,
          title: Text(role.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          value: (draft[key] as List).contains(role.id),
          onChanged: saving
              ? null
              : (checked) => setState(() {
                  final ids = List<String>.from(draft[key] as List)
                    ..remove(role.id);
                  if (checked == true) ids.add(role.id);
                  draft[key] = ids;
                }),
        ),
    ],
  );
  Future<void> save() async {
    final config = SocialConfig.fromJson(draft);
    if ((config.wechatPosts ||
            config.wechatComments ||
            config.qqPosts ||
            config.qqComments) &&
        !config.roleIds.any((id) => demo.personas.any((r) => r.id == id))) {
      setState(() => feedback = '请至少选择一位参与自动互动的角色。');
      return;
    }
    setState(() => saving = true);
    final ok = await settings.save(config);
    if (!mounted) return;
    setState(() {
      saving = false;
      feedback = ok ? '已保存' : settings.error;
    });
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      section('朋友圈与 QQ 空间', [
        toggle('wechatPosts', '角色自动发朋友圈', '开启后按设定间隔发布角色动态'),
        toggle('wechatComments', '角色自动评论朋友圈', '回应你发表的动态与评论'),
        const Divider(height: 1),
        toggle('qqPosts', '角色自动发空间动态', '开启后按设定间隔发布角色动态'),
        toggle('qqComments', '角色自动评论空间动态', '回应你发表的动态与评论'),
      ]),
      section('自动互动安排', [
        AnimatedBuilder(
          animation: socialActivity,
          builder: (context, _) => ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(
              '今日自动调用 ${socialActivity.usedToday} 次',
              style: const TextStyle(fontSize: 14),
            ),
            subtitle: Text(
              socialActivity.error ??
                  (socialActivity.busy ? '角色正在准备动态或评论…' : '应用前台按已保存的规则运行'),
              style: const TextStyle(fontSize: 12, height: 1.5),
            ),
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 10),
          child: Text(
            '使用当前模型连接，消耗相应额度；仅在应用前台运行。动态和评论共同计入每日调用上限。',
            style: TextStyle(fontSize: 12, height: 1.7),
          ),
        ),
        select('intervalMinutes', '动态发布间隔', {
          30: '30 分钟',
          60: '1 小时',
          180: '3 小时',
          360: '6 小时',
          720: '12 小时',
          1440: '每天',
        }),
        select('dailyLimit', '每日最多自动调用', {
          for (var i = 1; i <= 10; i++) i: '$i 次',
        }),
        const ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text('参与自动互动的角色', style: TextStyle(fontSize: 14)),
          subtitle: Text('从原角色列表选择；取消选择后停止该角色的自动互动'),
        ),
        roleList('roleIds'),
      ]),
      section('群聊默认规则', [
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 10),
          child: Text(
            '保存新建群聊的默认偏好。群聊对话功能开放后生效，现有单聊保持独立。',
            style: TextStyle(fontSize: 12, height: 1.7),
          ),
        ),
        select('groupRule', '回复方式', {
          for (final rule in GroupReplyRule.values) rule.name: rule.label,
        }),
        select('groupMaxReplies', '单轮最多回复角色', {
          for (var i = 1; i <= 6; i++) i: '$i 位',
        }),
        select('groupHistoryLimit', '群聊上下文消息数', {
          5: '最近 5 条',
          10: '最近 10 条',
          20: '最近 20 条',
          50: '最近 50 条',
          100: '最近 100 条',
        }),
        const ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text('默认群成员', style: TextStyle(fontSize: 14)),
        ),
        roleList('groupMembers'),
      ]),
      if (feedback != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(feedback!),
        ),
      FilledButton(
        onPressed: saving ? null : save,
        child: Text(saving ? '保存中…' : '保存设置'),
      ),
      const SizedBox(height: 16),
    ],
  );
}

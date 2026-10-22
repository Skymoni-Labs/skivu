import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'character_avatar.dart';
import 'state.dart';
import 'widgets.dart';
import 'voice_call_screen.dart';
import 'voice_call_session.dart';
import 'appearance_settings.dart';
import 'settings_home.dart';
import 'model_settings_page.dart';
import 'account_beta_page.dart';
import 'relay_account_page.dart';
import 'app_updates_page.dart';
import 'speech_settings_page.dart';

const settingsSections = <(String, String, String, IconData)>[
  ('account', '中转站账号', '登录、模型与额度同步', Icons.account_circle_outlined),
  ('updates', '检查更新', '新版本与手机内升级', Icons.system_update_outlined),
  ('beta', '内测计划', '申请状态与专属内测额度', Icons.science_outlined),
  ('models', '模型与服务', '管理连接，选择适合你的模型', Icons.hub_outlined),
  ('speech', '语音与通话', '合成服务、音色与语速', Icons.graphic_eq),
  ('appearance', '外观', '壁纸、主题与文字大小', Icons.palette_outlined),
  ('permissions', '隐私与权限', '了解数据如何使用', Icons.shield_outlined),
  ('data', '聊天记录', '本地保存、备份与清理', Icons.history),
  ('workspace', '工作区', '文件与工作空间偏好', Icons.folder_outlined),
  ('devices', '访问设备', '本机状态与配对流程', Icons.devices_outlined),
  ('about', '关于 Skivu', '版本信息与开源许可', Icons.info_outline),
];

class ContentPage extends StatelessWidget {
  const ContentPage({super.key, required this.route, required this.go});
  final String route;
  final ValueChanged<String> go;
  @override
  Widget build(BuildContext context) {
    if (route == '/call') return CallPage(go: go);
    Widget child;
    if (route == '/characters') {
      child = CharactersPage(go: go);
    } else if (route == '/characters/edit') {
      child = CharacterEditor(go: go);
    } else if (route == '/plugins' || route == '/market') {
      child = PluginsPage(market: route == '/market', go: go);
    } else if (route == '/settings') {
      child = settingsHome(context);
    } else if (route.startsWith('/settings/')) {
      child = SettingsDetail(section: route.split('/').last, go: go);
    } else {
      child = Column(
        children: [
          const PageHeading('A little detour', '这里暂时没有页面', '回到对话，继续你的想法。'),
          actionButton('返回对话', Icons.arrow_back, () => go('/chat')),
        ],
      );
    }
    return SingleChildScrollView(
      padding: EdgeInsets.all(MediaQuery.sizeOf(context).width < 700 ? 16 : 32),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: route.startsWith('/settings') ? 680 : 1050,
          ),
          child: child,
        ),
      ),
    );
  }

  Widget settingsHome(BuildContext context) => SettingsHome(go: go);
}

class CharactersPage extends StatefulWidget {
  const CharactersPage({super.key, required this.go});
  final ValueChanged<String> go;
  @override
  State<CharactersPage> createState() => _CharactersPageState();
}

class _CharactersPageState extends State<CharactersPage> {
  String group = '全部', query = '';
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      PageHeading(
        'A different perspective',
        '角色',
        '管理角色卡、分组与对话设定。',
        action: actionButton('创建角色', Icons.add, () {
          demo.personas.add(
            Persona(
              '新的伙伴',
              '写下一句角色介绍',
              '用温和、清晰的语言与用户交流。',
              '日常',
              green,
              Icons.face_outlined,
            ),
          );
          demo.persona = demo.personas.length - 1;
          demo.changed();
          widget.go('/characters/edit');
        }, filled: true),
      ),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final g in demo.groups)
            ChoiceChip(
              label: Text(g, style: const TextStyle(fontSize: 12)),
              selected: group == g,
              onSelected: (_) => setState(() => group = g),
            ),
          TextButton.icon(
            onPressed: groupDialog,
            icon: const Icon(Icons.create_new_folder_outlined, size: 16),
            label: const Text('管理分组', style: TextStyle(fontSize: 11)),
          ),
        ],
      ),
      const SizedBox(height: 20),
      TextField(
        decoration: const InputDecoration(
          hintText: '搜索角色名字或介绍',
          prefixIcon: Icon(Icons.search, size: 20),
        ),
        onChanged: (v) => setState(() => query = v),
      ),
      const SizedBox(height: 24),
      LayoutBuilder(
        builder: (c, box) => Wrap(
          spacing: 18,
          runSpacing: 18,
          children: [
            for (int i = 0; i < demo.personas.length; i++)
              if ((group == '全部' || demo.personas[i].group == group) &&
                  (demo.personas[i].name.contains(query) ||
                      demo.personas[i].subtitle.contains(query)))
                SizedBox(
                  width: box.maxWidth > 750
                      ? (box.maxWidth - 36) / 3
                      : box.maxWidth > 480
                      ? (box.maxWidth - 18) / 2
                      : box.maxWidth,
                  child: personaCard(i),
                ),
          ],
        ),
      ),
    ],
  );
  Widget personaCard(int i) {
    final p = demo.personas[i];
    return Pane(
      padding: const EdgeInsets.all(17),
      child: Column(
        children: [
          Row(
            children: [
              CharacterAvatar(persona: p, size: 52),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        label(p.name, size: 17, weight: FontWeight.w600),
                        const SizedBox(width: 8),
                        TinyTag(p.group, color: p.color),
                      ],
                    ),
                    const SizedBox(height: 3),
                    label(p.subtitle, size: 11, color: muted),
                  ],
                ),
              ),
              IconButton(
                tooltip: '编辑 ${p.name}',
                onPressed: () {
                  demo.persona = i;
                  widget.go('/characters/edit');
                },
                icon: const Icon(Icons.tune, size: 19, color: muted),
              ),
            ],
          ),
          const SizedBox(height: 15),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: () {
                demo.persona = i;
                demo.changed();
                widget.go('/chat');
              },
              child: const Text('开始对话', style: TextStyle(fontSize: 12)),
            ),
          ),
        ],
      ),
    );
  }

  void groupDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, change) => AlertDialog(
          title: const Text('管理角色分组'),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final g in demo.groups.where((g) => g != '全部'))
                      Chip(label: Text(g)),
                  ],
                ),
                const SizedBox(height: 18),
                TextField(
                  controller: controller,
                  decoration: const InputDecoration(hintText: '新分组名称'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('完成'),
            ),
            FilledButton(
              onPressed: () {
                final value = controller.text.trim();
                if (value.isEmpty || demo.groups.contains(value)) return;
                demo.groups.add(value);
                controller.clear();
                demo.changed();
                change(() {});
                setState(() {});
              },
              child: const Text('添加分组'),
            ),
          ],
        ),
      ),
    );
  }
}

class CharacterEditor extends StatefulWidget {
  const CharacterEditor({super.key, required this.go});
  final ValueChanged<String> go;
  @override
  State<CharacterEditor> createState() => _CharacterEditorState();
}

class _CharacterEditorState extends State<CharacterEditor> {
  late Uint8List? avatar = demo.role.avatar;
  bool pickingAvatar = false;
  Future<void> chooseAvatar() async {
    setState(() => pickingAvatar = true);
    try {
      final selected = await pickCharacterAvatar();
      if (mounted && selected != null) setState(() => avatar = selected);
    } catch (_) {
      if (mounted) toast(context, '头像未导入，请选择有效图片（最大 3 MB）。');
    } finally {
      if (mounted) setState(() => pickingAvatar = false);
    }
  }

  late final name = TextEditingController(text: demo.role.name),
      subtitle = TextEditingController(text: demo.role.subtitle),
      prompt = TextEditingController(text: demo.role.prompt);
  final cardFields = <String, TextEditingController>{
    for (final key in [
      '角色描述',
      '性格与说话方式',
      '场景与世界观',
      '与用户的关系',
      '示例对话',
      '开场白',
      '回复规则与边界',
    ])
      key: TextEditingController(text: demo.role.card[key] ?? ''),
  };
  late String group = demo.role.group;
  final form = GlobalKey<FormState>();
  @override
  void dispose() {
    name.dispose();
    subtitle.dispose();
    prompt.dispose();
    for (final field in cardFields.values) {
      field.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      TextButton.icon(
        onPressed: () => widget.go('/characters'),
        icon: const Icon(Icons.arrow_back, size: 16),
        label: const Text('角色空间'),
      ),
      const SizedBox(height: 16),
      const PageHeading('Shape a companion', '编辑角色卡', '设置角色名称、介绍与提示词。'),
      Form(
        key: form,
        child: Pane(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  InkWell(
                    onTap: pickingAvatar ? null : chooseAvatar,
                    child: CharacterAvatar(
                      persona: demo.role,
                      size: 64,
                      bytes: avatar,
                      showDefault: avatar == null,
                    ),
                  ),
                  const SizedBox(width: 20),
                  Expanded(
                    child: Wrap(
                      children: [
                        TextButton.icon(
                          onPressed: pickingAvatar ? null : chooseAvatar,
                          icon: const Icon(
                            Icons.add_photo_alternate_outlined,
                            size: 18,
                          ),
                          label: Text(pickingAvatar ? '正在导入…' : '更换头像'),
                        ),
                        if (avatar != null)
                          TextButton(
                            onPressed: pickingAvatar
                                ? null
                                : () => setState(() => avatar = null),
                            child: const Text('恢复默认头像'),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 26),
              TextFormField(
                controller: name,
                decoration: const InputDecoration(labelText: '角色名称'),
                validator: (v) =>
                    v == null || v.trim().isEmpty ? '给伙伴起个名字吧' : null,
              ),
              const SizedBox(height: 20),
              TextFormField(
                controller: subtitle,
                decoration: const InputDecoration(labelText: '一句话介绍'),
              ),
              const SizedBox(height: 20),
              DropdownButtonFormField<String>(
                initialValue: group,
                decoration: const InputDecoration(labelText: '分组'),
                items: [
                  for (final g in demo.groups.where((g) => g != '全部'))
                    DropdownMenuItem(value: g, child: Text(g)),
                ],
                onChanged: (v) => setState(() => group = v!),
              ),
              const SizedBox(height: 20),
              TextFormField(
                controller: prompt,
                minLines: 5,
                maxLines: 10,
                decoration: const InputDecoration(
                  labelText: '角色提示词',
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 12),
              label(
                '设定用于之后的对话，支持 {{char}} 与 {{user}}。留空的字段不会加入提示词。',
                size: 11,
                color: muted,
              ),
              for (final e in cardFields.entries) ...[
                const SizedBox(height: 18),
                TextFormField(
                  controller: e.value,
                  maxLength: 6000,
                  minLines: 2,
                  maxLines: 6,
                  decoration: InputDecoration(
                    labelText: e.key,
                    helperText: e.key == '示例对话'
                        ? '例如：用户：今天好累。角色：先坐下来，我听你说。'
                        : e.key == '开场白'
                        ? '仅新建对话时显示，不请求模型。'
                        : '可选；填写具体行为、背景与表达习惯。',
                    alignLabelWithHint: true,
                  ),
                ),
              ],
              const SizedBox(height: 28),
              Wrap(
                spacing: 12,
                children: [
                  actionButton('保存角色', Icons.check, () {
                    if (!form.currentState!.validate()) return;
                    demo.role.name = name.text.trim();
                    demo.role.avatar = avatar;
                    demo.role.subtitle = subtitle.text;
                    demo.role.prompt = prompt.text;
                    demo.role.group = group;
                    demo.role.card = {
                      for (final e in cardFields.entries)
                        e.key: e.value.text.trim(),
                    };
                    demo.changed();
                    demo.saveChats();
                    toast(context, '角色已保存');
                    widget.go('/characters');
                  }, filled: true),
                  actionButton(
                    '返回',
                    Icons.arrow_back,
                    () => widget.go('/characters'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ],
  );
}

class SettingsDetail extends StatefulWidget {
  const SettingsDetail({super.key, required this.section, required this.go});
  final String section;
  final ValueChanged<String> go;
  @override
  State<SettingsDetail> createState() => _SettingsDetailState();
}

class _SettingsDetailState extends State<SettingsDetail> {
  String workspace = demo.workspaceName;
  bool autoSave = demo.prefs['草稿自动保留'] ?? true;
  @override
  Widget build(BuildContext context) {
    final section = settingsSections
        .where((s) => s.$1 == widget.section)
        .firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextButton.icon(
          onPressed: () => widget.go('/settings'),
          icon: const Icon(Icons.arrow_back, size: 16),
          label: const Text('所有设置'),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 18),
          child: Text(
            section?.$3 ?? '选择你的偏好。',
            style: const TextStyle(fontSize: 12, height: 1.5, color: ink),
          ),
        ),
        switch (widget.section) {
          'account' => RelayAccountPage(go: widget.go),
          'updates' => const AppUpdatesPage(),
          'beta' => AccountBetaPage(go: widget.go),
          'models' => models(),
          'speech' => speech(),
          'appearance' => appearance(),
          'permissions' => const PrivacySettings(),
          'data' => data(),
          'workspace' => workspacePage(),
          'devices' => devices(),
          _ => about(),
        },
      ],
    );
  }

  Widget toggle(String key, String detail, {IconData? icon}) => SettingRow(
    key,
    detail,
    icon: icon,
    trailing: Switch(
      value: demo.prefs[key] ?? false,
      onChanged: (v) {
        demo.prefs[key] = v;
        demo.changed();
      },
    ),
  );
  Widget models() => const ModelSettingsPage();
  Widget speech() => const SpeechSettingsPage();
  Widget appearance() => const AppearanceSettings();
  Widget permissions() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Pane(
        child: Column(
          children: [
            toggle('文件读取', '只模拟偏好，不授予磁盘访问', icon: Icons.folder_outlined),
            const Divider(),
            toggle('浏览器访问', '只模拟偏好，不连接外部网页', icon: Icons.language),
            const Divider(),
            toggle('终端执行', '只模拟偏好，不执行系统指令', icon: Icons.terminal),
          ],
        ),
      ),
      const SizedBox(height: 22),
      Pane(
        color: demo.dark ? null : mist,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.shield_outlined, color: green),
            const SizedBox(width: 15),
            Expanded(
              child: label(
                '权限边界由你决定。\n这里的开关只改变 UI 状态；真实权限系统将在后续模块接入时逐项确认。',
                size: 12,
                color: muted,
              ),
            ),
          ],
        ),
      ),
    ],
  );
  Widget data() => const ChatDataSettings();
  Widget workspacePage() => Pane(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextFormField(
          initialValue: workspace,
          decoration: const InputDecoration(labelText: '演示工作区名称'),
          onChanged: (v) => workspace = v,
        ),
        const SizedBox(height: 16),
        SettingRow(
          '草稿自动保留',
          '示例笔记保留于当前会话内存，刷新后重置',
          trailing: Switch(
            value: autoSave,
            onChanged: (v) => setState(() => autoSave = v),
          ),
        ),
        const Divider(),
        const SettingRow(
          '演示文件数',
          '3 个示例文件 · 未连接实际目录',
          icon: Icons.description_outlined,
          trailing: TinyTag('隔离'),
        ),
        const SizedBox(height: 14),
        actionButton('保存工作区偏好', Icons.check, () {
          demo.workspaceName = workspace.trim().isEmpty
              ? '灵感空间'
              : workspace.trim();
          demo.prefs['草稿自动保留'] = autoSave;
          demo.changed();
          toast(context, '已保存「${demo.workspaceName}」的演示偏好');
        }, filled: true),
      ],
    ),
  );
  Widget devices() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Pane(
        child: Column(
          children: [
            const SettingRow(
              '当前浏览器',
              '本地 UI 预览 · 不采集设备标识',
              icon: Icons.laptop_mac,
              trailing: TinyTag('当前'),
            ),
            const Divider(),
            toggle('允许本机访问', '仅显示状态，不改变网络监听范围'),
            const Divider(),
            SettingRow(
              '配对新设备',
              '体验配对界面，不创建真实连接',
              icon: Icons.add_to_queue,
              onTap: () => showDialog(
                context: context,
                builder: (c) => AlertDialog(
                  title: const Text('设备配对演示'),
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 110,
                        height: 110,
                        decoration: BoxDecoration(
                          color: mist,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Icon(
                          Icons.devices_other,
                          size: 52,
                          color: green,
                        ),
                      ),
                      const SizedBox(height: 20),
                      label(
                        'S K I  ·  0 2 1',
                        size: 23,
                        color: green,
                        weight: FontWeight.w600,
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        '这是示例配对码，不可用于登录。\n没有开放远程访问或创建真实配对。',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                  actions: [
                    FilledButton(
                      onPressed: () => Navigator.pop(c),
                      child: const Text('完成演示'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 20),
      label('已连接设备：0 · 本阶段不提供远程访问服务。', size: 11, color: muted),
    ],
  );
  Widget about() => const SkivuAbout();
}

class PluginsPage extends StatelessWidget {
  const PluginsPage({super.key, required this.market, required this.go});
  final bool market;
  final ValueChanged<String> go;
  @override
  Widget build(BuildContext context) => Pane(
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 44),
      child: Column(
        children: [
          Icon(Icons.extension_outlined, size: 42, color: ink),
          const SizedBox(height: 20),
          label(market ? '插件市场' : '插件', size: 24, weight: FontWeight.w600),
          const SizedBox(height: 12),
          label('即将开放', size: 18),
          const SizedBox(height: 10),
          label('更多扩展能力正在准备中。', size: 12),
        ],
      ),
    ),
  );
}

class CallPage extends StatefulWidget {
  const CallPage({super.key, required this.go});
  final ValueChanged<String> go;
  @override
  State<CallPage> createState() => _CallPageState();
}

class _CallPageState extends State<CallPage> {
  late final session = VoiceCallSession();
  @override
  Widget build(BuildContext context) => VoiceCallScreen(
    session: session,
    roleName: demo.role.name,
    onHangUp: () => widget.go('/chat'),
  );
}

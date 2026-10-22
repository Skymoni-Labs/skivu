import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'state.dart';
import 'widgets.dart';
import 'voice_call_orb.dart';
import 'appearance_settings.dart';
import 'settings_home.dart';
import 'model_settings_page.dart';
import 'beta_settings_page.dart';
import 'relay_account_page.dart';
import 'app_updates_page.dart';

const settingsSections = <(String, String, String, IconData)>[
  ('account', '中转站账号', '登录、模型与额度同步', Icons.account_circle_outlined),
  ('updates', '检查更新', '新版本与手机内升级', Icons.system_update_outlined),
  ('beta', '内测计划', '设备配对与专属内测额度', Icons.science_outlined),
  ('models', '模型与服务', '管理连接，选择适合你的模型', Icons.hub_outlined),
  ('speech', '语音', '语音识别与声音合成', Icons.graphic_eq),
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
      padding: EdgeInsets.all(MediaQuery.sizeOf(context).width < 700 ? 24 : 42),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1050),
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
              CircleAvatar(
                radius: 26,
                backgroundColor: p.color.withValues(alpha: .12),
                child: Icon(p.icon, color: p.color, size: 26),
              ),
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
  late final name = TextEditingController(text: demo.role.name),
      subtitle = TextEditingController(text: demo.role.subtitle),
      prompt = TextEditingController(text: demo.role.prompt);
  late String group = demo.role.group;
  final form = GlobalKey<FormState>();
  @override
  void dispose() {
    name.dispose();
    subtitle.dispose();
    prompt.dispose();
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
                  CircleAvatar(
                    radius: 32,
                    backgroundColor: demo.role.color.withValues(alpha: .12),
                    child: Icon(
                      demo.role.icon,
                      size: 30,
                      color: demo.role.color,
                    ),
                  ),
                  const SizedBox(width: 20),
                  Expanded(
                    child: label(
                      '自主绘制的角色标识\n不使用第三方头像素材',
                      size: 11,
                      color: muted,
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
              label('此设定会作为角色提示词，用于之后的对话。', size: 11, color: muted),
              const SizedBox(height: 28),
              Wrap(
                spacing: 12,
                children: [
                  actionButton('保存角色', Icons.check, () {
                    if (!form.currentState!.validate()) return;
                    demo.role.name = name.text.trim();
                    demo.role.subtitle = subtitle.text;
                    demo.role.prompt = prompt.text;
                    demo.role.group = group;
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
        const SizedBox(height: 18),
        PageHeading(
          'Your preferences',
          section?.$2 ?? '设置',
          section?.$3 ?? '选择你的偏好。',
        ),
        switch (widget.section) {
          'account' => RelayAccountPage(go: widget.go),
          'updates' => const AppUpdatesPage(),
          'beta' => BetaSettingsPage(go: widget.go),
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
  Widget speech() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Pane(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            label('语音识别', size: 16, weight: FontWeight.w500),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              initialValue: demo.recognition,
              decoration: const InputDecoration(labelText: '识别方式'),
              items: [
                for (final v in ['浏览器演示识别', '本地识别 · 待接入', '云端识别 · 待接入'])
                  DropdownMenuItem(
                    value: v,
                    child: Text(v, style: const TextStyle(fontSize: 12)),
                  ),
              ],
              onChanged: (v) {
                demo.recognition = v!;
                demo.changed();
              },
            ),
            const SizedBox(height: 20),
            label('语音合成', size: 16, weight: FontWeight.w500),
            const SizedBox(height: 14),
            Wrap(
              spacing: 10,
              children: [
                for (final v in ['清澈', '温暖', '沉静'])
                  ChoiceChip(
                    label: Text(v),
                    selected: demo.voice == v,
                    onSelected: (_) {
                      demo.voice = v;
                      demo.changed();
                    },
                  ),
              ],
            ),
            const SizedBox(height: 18),
            toggle('声音反馈', '仅切换演示偏好，不播放音频'),
            const SizedBox(height: 10),
            actionButton(
              '体验语音通话',
              Icons.graphic_eq,
              () => widget.go('/call'),
              filled: true,
            ),
          ],
        ),
      ),
      const SizedBox(height: 18),
      label('本阶段不请求麦克风权限，不采集、不识别、不播放真实语音。', size: 11, color: muted),
    ],
  );
  Widget appearance() => const Pane(child: AppearanceSettings());
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

class PluginsPage extends StatefulWidget {
  const PluginsPage({super.key, required this.market, required this.go});
  final bool market;
  final ValueChanged<String> go;
  @override
  State<PluginsPage> createState() => _PluginsPageState();
}

class _PluginsPageState extends State<PluginsPage> {
  String query = '';
  String category = '全部';
  List<(String, String, String, IconData, Color)> get catalog =>
      <(String, String, String, IconData, Color)>[
        ('灵感笔记', '随手记录，把想法留在当下。', '效率', Icons.edit_note, green),
        ('轻计划', '把一个大目标，变成小步骤。', '效率', Icons.checklist, Color(0xff859a65)),
        (
          '文字工坊',
          '打磨表达，让文字恰如其分。',
          '创作',
          Icons.auto_fix_high_outlined,
          Color(0xffab805c),
        ),
        (
          '灵感漫游',
          '用一个问题，打开另一种可能。',
          '创作',
          Icons.explore_outlined,
          Color(0xff7e8daa),
        ),
      ];
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      PageHeading(
        widget.market ? 'Room to explore' : 'A little more possibility',
        widget.market ? '插件市场' : '插件管理',
        widget.market ? '这里的每一个条目，都是独立编写的概念插件示例。' : '选择适合你的工具，保持空间的轻盈。',
        action: actionButton(
          widget.market ? '已添加的插件' : '探索市场',
          widget.market ? Icons.extension_outlined : Icons.north_east,
          () => widget.go(widget.market ? '/plugins' : '/market'),
        ),
      ),
      if (widget.market) ...[
        Pane(
          color: demo.dark ? null : const Color(0xffe2ecf8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const TinyTag('精选 / CONCEPT'),
                    const SizedBox(height: 14),
                    label('拓展你的 Skivu', size: 22, weight: FontWeight.w500),
                    const SizedBox(height: 8),
                    label('从一条笔记开始，建立自己的工作节奏。', size: 12, color: muted),
                  ],
                ),
              ),
              Icon(Icons.eco_outlined, size: 68, color: green),
            ],
          ),
        ),
        const SizedBox(height: 25),
      ],
      TextField(
        decoration: const InputDecoration(
          hintText: '搜索概念插件',
          prefixIcon: Icon(Icons.search, size: 20),
        ),
        onChanged: (v) => setState(() => query = v),
      ),
      const SizedBox(height: 16),
      Wrap(
        spacing: 8,
        children: [
          for (final cat in ['全部', '效率', '创作'])
            ChoiceChip(
              label: Text(cat),
              selected: cat == category,
              onSelected: (_) => setState(() => category = cat),
            ),
        ],
      ),
      const SizedBox(height: 23),
      LayoutBuilder(
        builder: (context, box) => Wrap(
          spacing: 16,
          runSpacing: 16,
          children: [
            for (final p in catalog)
              if ((widget.market || demo.installed.contains(p.$1)) &&
                  p.$1.contains(query) &&
                  (category == '全部' || category == p.$3))
                SizedBox(
                  width: box.maxWidth > 650
                      ? (box.maxWidth - 16) / 2
                      : box.maxWidth,
                  child: Pane(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 46,
                              height: 46,
                              decoration: BoxDecoration(
                                color: p.$5.withValues(alpha: .12),
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: Icon(p.$4, color: p.$5),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  label(
                                    p.$1,
                                    size: 16,
                                    weight: FontWeight.w500,
                                  ),
                                  label(
                                    'Skivu 自主概念 · ${p.$3}',
                                    size: 10,
                                    color: muted,
                                  ),
                                ],
                              ),
                            ),
                            const TinyTag('演示'),
                          ],
                        ),
                        const SizedBox(height: 18),
                        label(p.$2, size: 12, color: muted),
                        const SizedBox(height: 20),
                        Row(
                          children: [
                            TextButton(
                              onPressed: () => details(p),
                              child: const Text(
                                '查看详情',
                                style: TextStyle(fontSize: 11),
                              ),
                            ),
                            const Spacer(),
                            OutlinedButton(
                              onPressed: () {
                                if (demo.installed.contains(p.$1)) {
                                  demo.installed.remove(p.$1);
                                } else {
                                  demo.installed.add(p.$1);
                                }
                                demo.changed();
                                setState(() {});
                                toast(
                                  context,
                                  demo.installed.contains(p.$1)
                                      ? '已添加概念插件，没有下载或运行代码'
                                      : '已移出演示插件列表',
                                );
                              },
                              child: Text(
                                demo.installed.contains(p.$1)
                                    ? '移除'
                                    : '添加到 Skivu',
                                style: const TextStyle(fontSize: 11),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
          ],
        ),
      ),
      if (!widget.market && demo.installed.isEmpty)
        Padding(
          padding: const EdgeInsets.all(30),
          child: Center(
            child: label('还没有插件。去市场挑一个概念示例吧。', size: 12, color: muted),
          ),
        ),
      const SizedBox(height: 24),
      label('所有条目仅改变本地演示列表，不下载、安装或执行插件包。', size: 11, color: muted),
    ],
  );
  void details((String, String, String, IconData, Color) p) => showDialog(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(p.$1),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            label(p.$2, size: 14),
            const SizedBox(height: 20),
            const TinyTag('第一方概念示例'),
            const SizedBox(height: 15),
            label(
              '版本：0.1 concept\n作者：Skivu\n权限：无真实权限\n来源：本工程自主编写\n状态：没有插件运行时或外部依赖',
              size: 12,
              color: muted,
            ),
            const SizedBox(height: 16),
            const Text('可到工作区「工具」面板查看固定演示结果。', style: TextStyle(fontSize: 12)),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('关闭')),
      ],
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
  final level = ValueNotifier<double>(0);
  Timer? elapsedTimer;
  bool transcript = false;
  DateTime? began;

  @override
  void initState() {
    super.initState();
    elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (demo.callActive) setState(() {});
    });
  }

  ValueNotifier<double> get orbLevel {
    level.value = demo.callActive
        ? (demo.speaking ? .55 : (demo.mutedCall ? 0 : .08))
        : 0;
    return level;
  }

  @override
  void dispose() {
    elapsedTimer?.cancel();
    level.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) => SingleChildScrollView(
      child: SizedBox(
        height: math.max(650, box.maxHeight),
        child: Column(
          children: [
            const SizedBox(height: 30),
            const TinyTag('语音通话 · 本地演示'),
            const SizedBox(height: 20),
            label('此刻，听见你的想法。', size: 26, weight: FontWeight.w500),
            const SizedBox(height: 7),
            label(
              '${demo.role.name} · ${demo.voice}声音',
              size: 12,
              color: muted,
            ),
            Expanded(
              child: Center(
                child: SizedBox(
                  width: 280,
                  height: 280,
                  child: VoiceCallOrb(
                    level: orbLevel,
                    dark: demo.dark,
                    reducedMotion: demo.prefs['减少动态效果'] ?? false,
                    semanticLabel: demo.callActive && demo.speaking
                        ? '水滴光球，轻触结束回应演示'
                        : '水滴光球',
                    onTap: () {
                      if (demo.callActive && demo.speaking) {
                        demo.speaking = false;
                        demo.changed();
                      }
                    },
                  ),
                ),
              ),
            ),
            label(
              demo.callActive
                  ? (demo.mutedCall
                        ? '麦克风已静音 · 演示'
                        : demo.speaking
                        ? '${demo.role.name} 正在回应 · 演示'
                        : '正在聆听 · 演示')
                  : '准备好，开始一段轻松的对话',
              size: 15,
              color: green,
            ),
            const SizedBox(height: 8),
            label(
              demo.callActive
                  ? '${began == null ? 0 : DateTime.now().difference(began!).inMinutes}:${(began == null ? 0 : DateTime.now().difference(began!).inSeconds % 60).toString().padLeft(2, '0')} · 未连接语音服务'
                  : '水滴光球 · 原创液体材质',
              size: 10,
              color: muted,
            ),
            const SizedBox(height: 24),
            if (transcript)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Pane(
                  padding: const EdgeInsets.all(15),
                  child: label(
                    '演示字幕\n你：想聊聊今天的灵感。\nski：我在，慢慢说。',
                    size: 12,
                    color: muted,
                  ),
                ),
              ),
            const SizedBox(height: 20),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 18,
              runSpacing: 16,
              children: [
                callControl(
                  demo.mutedCall ? Icons.mic_off_outlined : Icons.mic_none,
                  '静音',
                  () {
                    demo.mutedCall = !demo.mutedCall;
                    demo.changed();
                  },
                ),
                callControl(
                  Icons.closed_caption_outlined,
                  '字幕',
                  () => setState(() => transcript = !transcript),
                ),
                callControl(
                  demo.callActive ? Icons.call_end : Icons.call_outlined,
                  demo.callActive ? '结束演示' : '开始演示',
                  () {
                    demo.callActive = !demo.callActive;
                    began = demo.callActive ? DateTime.now() : null;
                    demo.changed();
                  },
                  primary: true,
                ),
                callControl(Icons.graphic_eq, '切换回应', () {
                  if (!demo.callActive) {
                    toast(context, '先开始通话演示');
                    return;
                  }
                  demo.speaking = !demo.speaking;
                  demo.changed();
                }),
              ],
            ),
            const SizedBox(height: 28),
            label('不请求麦克风权限 · 不录音 · 不播放真实语音', size: 10, color: muted),
            const SizedBox(height: 18),
            TextButton(
              onPressed: () {
                demo.callActive = false;
                demo.changed();
                widget.go('/chat');
              },
              child: const Text('回到对话', style: TextStyle(fontSize: 12)),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    ),
  );
  Widget callControl(
    IconData icon,
    String title,
    VoidCallback action, {
    bool primary = false,
  }) => Column(
    children: [
      IconButton.filledTonal(
        tooltip: title,
        onPressed: action,
        style: IconButton.styleFrom(
          backgroundColor: primary
              ? (demo.callActive ? const Color(0xffb96558) : green)
              : mist,
          foregroundColor: primary ? Colors.white : green,
          fixedSize: const Size(52, 52),
        ),
        icon: Icon(icon, size: 23),
      ),
      const SizedBox(height: 8),
      label(title, size: 10, color: muted),
    ],
  );
}

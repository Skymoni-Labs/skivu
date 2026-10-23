import 'package:flutter/material.dart';
import 'appearance.dart';
import 'appearance_profiles.dart';
import 'chat_bubble_surface.dart';
import 'assistant_reply_layout.dart';
import 'character_avatar.dart';
import 'glass.dart';
import 'glass_settings.dart';
import 'wallpaper_settings.dart';
import 'state.dart';
import 'widgets.dart';

class AppearanceSettings extends StatefulWidget {
  const AppearanceSettings({super.key, this.preferences});
  final AppearancePreferences? preferences;
  @override
  State<AppearanceSettings> createState() => _AppearanceSettingsState();
}

class _AppearanceSettingsState extends State<AppearanceSettings> {
  int section = 0;
  AppearancePreferences get model => widget.preferences ?? appearance;
  void change(String key, dynamic value) {
    model.set(key, value);
    model.save();
  }

  Widget gap([double height = 18]) => SizedBox(height: height);
  Widget title(String text) => Padding(
    padding: const EdgeInsets.only(top: 20, bottom: 10),
    child: label(text, size: 16, weight: FontWeight.w600),
  );
  Widget description(String text) => label(text, size: 11, color: muted);
  Widget toggle(String key, String text, {String? note}) =>
      SwitchListTile.adaptive(
        key: ValueKey('appearance-$key'),
        contentPadding: EdgeInsets.zero,
        title: Text(text, style: const TextStyle(fontSize: 13)),
        subtitle: note == null
            ? null
            : Text(note, style: const TextStyle(fontSize: 11)),
        value: model.flag(key),
        onChanged: (v) => change(key, v),
      );
  Widget choices(String key, String text, Map<String, String> values) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      label(text, size: 13),
      gap(8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: values.entries
            .map(
              (e) => ChoiceChip(
                key: ValueKey('appearance-$key-${e.key}'),
                label: Text(e.value),
                selected: model.text(key) == e.key,
                onSelected: (_) => change(key, e.key),
              ),
            )
            .toList(),
      ),
      gap(14),
    ],
  );
  Widget slider(
    String key,
    String text,
    double min,
    double max, {
    bool percent = false,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      label(
        '$text · ${percent ? '${(model.number(key) * 100).round()}%' : model.number(key).round()}',
        size: 13,
      ),
      Slider(
        key: ValueKey('appearance-$key'),
        value: model.number(key),
        min: min,
        max: max,
        divisions: ((max - min) * (percent ? 100 : 1)).round(),
        semanticFormatterCallback: (v) =>
            '$text ${percent ? '${(v * 100).round()}%' : v.round()}',
        onChanged: (v) => model.set(key, v),
        onChangeEnd: (_) => model.save(),
      ),
    ],
  );
  Future<String?> nameDialog(String heading, {String text = ''}) async {
    final controller = TextEditingController(text: text);
    final result = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(heading),
        content: TextField(
          controller: controller,
          maxLength: 40,
          autofocus: true,
          decoration: const InputDecoration(labelText: '方案名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (controller.text.trim().isNotEmpty)
                Navigator.pop(c, controller.text.trim());
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    // The dialog route may still be animating while its field is attached.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    controller.dispose();
    return result;
  }

  Future<void> colorDialog(String key, String text) async {
    final controller = TextEditingController(
      text:
          '#${model.color(key).toARGB32().toRadixString(16).substring(2).toUpperCase()}',
    );
    String? error;
    final picked = await showDialog<int>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, update) => AlertDialog(
          title: Text(text),
          titleTextStyle: const TextStyle(
            color: Color(0xff17212b),
            fontSize: 20,
          ),
          scrollable: true,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final swatch in const {
                    '深黑': 0xff17212b,
                    '靛蓝': 0xff1d4ed8,
                    '墨绿': 0xff166534,
                    '紫色': 0xff7e22ce,
                    '红棕': 0xff9a3412,
                    '灰色': 0xff64748b,
                    '白色': 0xffffffff,
                  }.entries)
                    ActionChip(
                      label: Text(
                        swatch.key,
                        style: const TextStyle(color: Color(0xff17212b)),
                      ),
                      avatar: CircleAvatar(
                        radius: 8,
                        backgroundColor: Color(swatch.value),
                      ),
                      onPressed: () => update(() {
                        controller.text =
                            '#${swatch.value.toRadixString(16).substring(2).toUpperCase()}';
                        error = null;
                      }),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              TextField(
                key: const ValueKey('color-hex-input'),
                controller: controller,
                style: const TextStyle(color: Color(0xff17212b)),
                maxLength: 7,
                decoration: InputDecoration(
                  labelText: '颜色 HEX',
                  hintText: '#347DA3',
                  labelStyle: const TextStyle(color: Color(0xff17212b)),
                  hintStyle: const TextStyle(color: Color(0xff39434f)),
                  counterStyle: const TextStyle(color: Color(0xff39434f)),
                  errorText: error,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text(
                '取消',
                style: TextStyle(color: Color(0xff17212b)),
              ),
            ),
            FilledButton(
              onPressed: () {
                final raw = controller.text.trim().replaceFirst('#', '');
                if (!RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(raw)) {
                  update(() => error = '请输入 6 位 RGB，例如 #347DA3');
                  return;
                }
                Navigator.pop(c, int.parse(raw, radix: 16) | 0xff000000);
              },
              child: const Text(
                '应用',
                style: TextStyle(color: Color(0xff17212b)),
              ),
            ),
          ],
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 250));
    controller.dispose();
    if (picked != null) {
      model.set(key, picked);
      if (key == 'userColor' || key == 'assistantColor') {
        model.set('customMessageColors', true);
      } else if (textColorKeys.contains(key)) {
        model.set('customTextColors', true);
      }
      await model.save();
    }
  }

  Widget colorRow(String key, String text) => ListTile(
    key: ValueKey('appearance-color-$key'),
    contentPadding: EdgeInsets.zero,
    title: Text(text, style: const TextStyle(fontSize: 13)),
    subtitle: Text(
      '#${model.color(key).toARGB32().toRadixString(16).substring(2).toUpperCase()}',
    ),
    trailing: Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(
        color: model.color(key),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: muted),
      ),
    ),
    onTap: () => colorDialog(key, text),
  );
  static const textColorKeys = [
    'interfaceText',
    'inputText',
    'userText',
    'assistantText',
    'thinkingText',
  ];
  Widget textColors({bool includeInterface = true}) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      title('字体颜色'),
      toggle(
        'customTextColors',
        '自定义字体颜色',
        note: '分别设置文字颜色；关闭后恢复默认深色，不改变气泡底色。',
      ),
      for (final entry in {
        if (includeInterface) 'interfaceText': '界面文字颜色',
        if (includeInterface) 'inputText': '输入框文字颜色',
        'userText': '我的消息文字颜色',
        'assistantText': '角色回复文字颜色',
        'thinkingText': '思考过程文字颜色',
      }.entries)
        colorRow(entry.key, entry.value),
      TextButton(
        style: TextButton.styleFrom(
          foregroundColor: const Color(0xff17212b),
          backgroundColor: const Color(0xffeef2f7),
        ),
        onPressed: () => model.resetSection(
          includeInterface
              ? ['customTextColors', ...textColorKeys]
              : ['userText', 'assistantText', 'thinkingText'],
        ),
        child: Text(includeInterface ? '恢复默认字体颜色' : '恢复消息文字颜色'),
      ),
    ],
  );
  Widget font(String key, String heading) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      choices(key, heading, {
        if (key != 'font') 'inherit': '跟随界面',
        'sans': '无衬线',
        'serif': '衬线',
        'mono': '等宽',
        if (model.text(key == 'font' ? 'fontAsset' : '${key}Asset').isNotEmpty)
          'custom': '自定义',
      }),
      OutlinedButton.icon(
        onPressed: model.busy ? null : () => model.pickFont(key),
        icon: const Icon(Icons.font_download_outlined, size: 18),
        label: Text('导入${heading}'),
      ),
      gap(12),
    ],
  );
  Widget profiles() => AnimatedBuilder(
    animation: appearanceProfiles,
    builder: (context, _) {
      final p = appearanceProfiles;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          label('我的外观方案', size: 16, weight: FontWeight.w600),
          gap(8),
          if (p.items.isNotEmpty)
            DropdownButtonFormField<String>(
              initialValue: p.active,
              key: ValueKey('appearance-profile-${p.active}'),
              isExpanded: true,
              decoration: const InputDecoration(labelText: '切换已保存方案'),
              items: p.items
                  .map(
                    (v) => DropdownMenuItem(
                      value: v['id'] as String,
                      child: Text(
                        v['name'] as String,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                  .toList(),
              onChanged: p.busy
                  ? null
                  : (id) {
                      if (id != null) p.apply(id);
                    },
            ),
          gap(8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              OutlinedButton.icon(
                onPressed: p.busy
                    ? null
                    : () async {
                        final name = await nameDialog('保存当前外观');
                        if (name != null) await p.create(name);
                      },
                icon: const Icon(Icons.add, size: 18),
                label: const Text('保存为方案'),
              ),
              if (p.active != null)
                TextButton(
                  onPressed: p.busy
                      ? null
                      : () async {
                          final name = await nameDialog(
                            '重命名方案',
                            text:
                                p.items.firstWhere(
                                      (v) => v['id'] == p.active,
                                    )['name']
                                    as String,
                          );
                          if (name != null) await p.rename(name);
                        },
                  child: const Text('重命名'),
                ),
              if (p.active != null)
                TextButton(
                  onPressed: p.busy ? null : p.remove,
                  child: const Text('删除方案'),
                ),
            ],
          ),
          description('保存主题、字体、背景、气泡、玻璃和信息显示；调整后可另存一套。'),
          if (p.error != null)
            Text(
              p.error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      );
    },
  );
  Widget preview() => ExpansionTile(
    tilePadding: EdgeInsets.zero,
    initiallyExpanded: true,
    title: const Text('实时预览', style: TextStyle(fontSize: 14)),
    children: [
      ConfigurableGlassSurface(
        area: 'toolbarBlur',
        radius: model.flag('capsuleToolbar') ? 16 : 0,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Icon(Icons.menu, color: green),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Skivu · 你好，世界 Aa 123',
                  style: TextStyle(color: model.textColor('interfaceText')),
                ),
              ),
              Icon(Icons.space_dashboard_outlined, color: green),
            ],
          ),
        ),
      ),
      gap(12),
      Padding(
        key: const ValueKey('appearance-chat-preview'),
        padding: EdgeInsets.symmetric(
          horizontal: model.flag('wideChat') ? 8 : 14,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: ChatBubbleSurface(
                user: true,
                child: Text(
                  '今天想和你聊一会儿。',
                  style: chatMessageStyle(
                    context,
                    true,
                    size: 13,
                    preferences: model,
                  ),
                ),
              ),
            ),
            gap(10),
            AssistantReplyLayout(
              layout: model.text('assistantBubbleLayout'),
              wide: model.flag('wideChat'),
              thinkingColor: model.textColor('thinkingText'),
              avatar: model.flag('avatars')
                  ? CharacterAvatar(
                      key: const ValueKey('preview-role-avatar'),
                      persona: demo.role,
                      size: 32,
                      square: model.flag('squareAvatars'),
                    )
                  : null,
              thinking: model.flag('showThinking') ? '先听你说，再一起整理今天的想法。' : null,
              child: ChatBubbleSurface(
                key: const ValueKey('preview-assistant-bubble'),
                user: false,
                contentPadding: AssistantReplyLayout.bubblePadding(
                  model.text('assistantBubbleLayout'),
                ),
                child: Text(
                  '我在，慢慢说就好。可以先聊聊今天发生的事情，我们再一起安排接下来的计划。',
                  style: chatMessageStyle(
                    context,
                    false,
                    size: 13,
                    preferences: model,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      gap(12),
      ConfigurableGlassSurface(
        area: 'inputBlur',
        radius: model.flag('floatingInput') ? 24 : 0,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '在这里写下你的想法…',
                  style: TextStyle(
                    fontSize: 13,
                    color: model.textColor('inputText'),
                  ),
                ),
              ),
              Icon(Icons.arrow_upward, color: green),
            ],
          ),
        ),
      ),
      gap(),
    ],
  );
  Widget theme() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      title('主题色'),
      Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          for (final item in <(String, int)>[
            ('晴空', 0xff347da3),
            ('苔绿', 0xff578878),
            ('暖杏', 0xffb27848),
            ('蔷薇', 0xffa46487),
            ('暮紫', 0xff7463a5),
          ])
            ChoiceChip(
              label: Text(item.$1),
              avatar: CircleAvatar(backgroundColor: Color(item.$2), radius: 8),
              selected: model.color('accent').toARGB32() == item.$2,
              onSelected: (_) => change('accent', item.$2),
            ),
          ActionChip(
            label: const Text('自定义'),
            onPressed: () => colorDialog('accent', '主题颜色'),
          ),
        ],
      ),
      gap(),
      choices('mode', '明暗模式', {'light': '浅色', 'dark': '深色', 'system': '跟随系统'}),
      font('font', '界面字体'),
      textColors(),
      description('内置中文无衬线、中文衬线和西文等宽字体；自定义字体仅存本机。'),
      gap(),
      slider('uiScale', '界面缩放', .8, 1.2, percent: true),
      slider('textScale', '字体大小', .8, 1.4, percent: true),
      description('语言：简体中文。等宽字体未覆盖的汉字使用内置中文字体。'),
      TextButton(
        onPressed: () => model.resetSection([
          'accent',
          'mode',
          'font',
          'fontAsset',
          'uiScale',
          'textScale',
          'customTextColors',
          ...textColorKeys,
        ]),
        child: const Text('恢复主题与文字默认值'),
      ),
    ],
  );
  Widget background() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      title('背景与壁纸'),
      toggle('backgroundEnabled', '显示自定义背景'),
      slider('backgroundOpacity', '背景可见度', 0, 1, percent: true),
      choicesForMedia(),
      WallpaperSettings(
        onChosen: () {
          model.set('videoAsset', '');
          model.set('backgroundEnabled', true);
          model.save();
        },
      ),
      gap(),
      OutlinedButton.icon(
        onPressed: model.busy ? null : model.pickVideo,
        icon: const Icon(Icons.video_library_outlined),
        label: Text(model.text('videoAsset').isEmpty ? '选择背景视频' : '更换背景视频'),
      ),
      if (model.text('videoAsset').isNotEmpty) ...[
        description('视频已选取 · 静音循环 · 退到后台暂停'),
        slider('videoBlur', '视频模糊', 0, 18),
        slider('videoDim', '视频压暗', 0, .65, percent: true),
        TextButton(
          onPressed: () => change('videoAsset', ''),
          child: const Text('使用图片背景'),
        ),
      ],
      description('背景视频最大 30 MB；开启减少动态效果时暂停。全部媒体保存在本机。'),
    ],
  );
  Widget choicesForMedia() => model.text('videoAsset').isNotEmpty
      ? Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: description('当前显示视频，选择图片可切换为图片背景。'),
        )
      : const SizedBox();
  void messagePalette(int i) {
    if (i == 0) {
      change('customMessageColors', false);
      return;
    }
    final values = <List<int>>[
      [0xffc9e6ff, 0xffedf4fa, 0xff234f69, 0xff283947],
      [0xffd7eee3, 0xffedf4ee, 0xff285640, 0xff284033],
      [0xffd5dde6, 0xffe2e7ed, 0xff17212b, 0xff17212b],
    ][i - 1];
    for (final e in ['userColor', 'assistantColor'].asMap().entries) {
      model.set(e.value, values[e.key]);
    }
    model.set('customMessageColors', true);
    model.save();
  }

  Widget messages() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      title('消息版式'),
      choices('bubbleStyle', '版式', {'bubble': '对话气泡', 'document': '阅读式'}),
      choices('assistantBubbleLayout', '角色回复宽度', assistantBubbleLayouts),
      toggle('compact', '紧凑消息间距'),
      toggle('wideChat', '加宽聊天内容'),
      choices('bubbleShape', '气泡形状', {
        'rounded': '圆矩形',
        'rectangle': '直角矩形',
        'tail': '对话尾角',
        'pill': '柔和圆角',
      }),
      toggle('rounded', '启用圆角'),
      title('消息配色'),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final e in ['跟随主题', '清透蓝', '浅苔绿', '雾灰'].asMap().entries)
            ActionChip(
              label: Text(e.value),
              onPressed: () => messagePalette(e.key),
            ),
        ],
      ),
      toggle('customMessageColors', '使用自定义气泡底色'),
      for (final e in {
        'userColor': '我的气泡底色',
        'assistantColor': '回复气泡底色',
      }.entries)
        colorRow(e.key, e.value),
      slider('userOpacity', '我的气泡不透明度', 0, 1, percent: true),
      slider('assistantOpacity', '回复气泡不透明度', 0, 1, percent: true),
      title('气泡字体'),
      font('userFont', '我的消息字体'),
      font('assistantFont', '回复消息字体'),
      textColors(includeInterface: false),
      title('气泡贴图'),
      for (final user in [true, false]) ...[
        label(user ? '我的消息贴图' : '回复消息贴图', size: 13),
        gap(8),
        if (appearanceAssets.image(
              model.text(user ? 'userImage' : 'assistantImage'),
            )
            case final image?)
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.memory(
              image,
              height: 70,
              width: 140,
              fit: BoxFit.cover,
            ),
          ),
        Wrap(
          spacing: 8,
          children: [
            OutlinedButton(
              onPressed: model.busy ? null : () => model.pickBubbleImage(user),
              child: const Text('选择图片'),
            ),
            if (model.text(user ? 'userImage' : 'assistantImage').isNotEmpty)
              TextButton(
                onPressed: () =>
                    change(user ? 'userImage' : 'assistantImage', ''),
                child: const Text('移除贴图'),
              ),
          ],
        ),
        gap(12),
      ],
      TextButton(
        onPressed: () => model.resetSection([
          'bubbleStyle',
          'compact',
          'wideChat',
          'rounded',
          'bubbleShape',
          'assistantBubbleLayout',
          'customMessageColors',
          'userColor',
          'assistantColor',
          'userText',
          'assistantText',
          'thinkingText',
          'userOpacity',
          'assistantOpacity',
          'userFont',
          'assistantFont',
          'userFontAsset',
          'assistantFontAsset',
          'userImage',
          'assistantImage',
        ]),
        child: const Text('恢复消息外观默认值'),
      ),
    ],
  );
  Widget glass() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      toggle('glass', '启用玻璃材质'),
      const GlassSettings(),
      slider('leftOpacity', '左侧栏不透明度', 0, 1, percent: true),
      slider('rightOpacity', '右侧栏不透明度', 0, 1, percent: true),
      title('输入框与顶栏'),
      toggle('capsuleToolbar', '胶囊顶栏', note: '开启为折射玻璃胶囊；关闭为延伸到屏幕顶部的长方形玻璃顶栏。'),
      slider('inputBlur', '输入框玻璃模糊', 0, 30),
      slider('inputOpacity', '输入框不透明度', 0, 1, percent: true),
      slider('toolbarBlur', '顶栏玻璃模糊', 0, 30),
      slider('toolbarOpacity', '顶栏不透明度', 0, 1, percent: true),
      TextButton(
        onPressed: () => model.resetSection([
          'inputBlur',
          'inputOpacity',
          'toolbarBlur',
          'toolbarOpacity',
          'capsuleToolbar',
          'leftOpacity',
          'rightOpacity',
        ]),
        child: const Text('恢复区域玻璃默认值'),
      ),
      gap(),
      const BubbleGlassSettings(),
    ],
  );
  Widget interaction() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      title('头像'),
      toggle('avatars', '显示消息头像'),
      toggle('squareAvatars', '使用方形头像'),
      title('输入框'),
      toggle('showUsage', '显示输入框下方统计', note: '轮次、速度、用量与占用率保持一行。'),
      choices('inputStyle', '输入布局', {'expanded': '展开工具栏', 'compact': '紧凑单行'}),
      toggle('floatingInput', '悬浮输入框'),
      title('动态与状态'),
      toggle('reduceMotion', '减少动态效果'),
      toggle('showStatus', '显示回复生成状态'),
      toggle('showThinking', '显示思考过程', note: '回复包含思考内容时显示，可折叠查看。'),
      title('消息信息'),
      for (final e in {
        'showRole': '角色名称',
        'showUser': '我的名称',
        'showModel': '模型名称',
        'showProvider': '模型供应商',
        'showTokens': 'Token 统计',
        'showElapsed': '响应耗时',
        'showTime': '消息时间',
      }.entries)
        toggle(e.key, e.value),
      description('未接入模型的数据以“—”显示；消息时间记录本地创建时刻。'),
      TextButton(
        onPressed: () => model.resetSection([
          'avatars',
          'squareAvatars',
          'inputStyle',
          'floatingInput',
          'reduceMotion',
          'showStatus',
          'showThinking',
          'showRole',
          'showUser',
          'showModel',
          'showProvider',
          'showTokens',
          'showElapsed',
          'showTime',
        ]),
        child: const Text('恢复交互与信息默认值'),
      ),
    ],
  );
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: model,
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        profiles(),
        gap(),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final e in [
              '主题文字',
              '背景',
              '消息气泡',
              '玻璃材质',
              '交互信息',
            ].asMap().entries)
              ChoiceChip(
                key: ValueKey('appearance-tab-${e.key}'),
                label: Text(e.value),
                selected: section == e.key,
                onSelected: (_) => setState(() => section = e.key),
              ),
          ],
        ),
        gap(),
        preview(),
        switch (section) {
          0 => theme(),
          1 => background(),
          2 => messages(),
          3 => glass(),
          _ => interaction(),
        },
        if (model.busy) const LinearProgressIndicator(),
        if (model.error != null)
          Text(
            model.error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        gap(),
        description('即时生效 · 调节结束自动保存 · 重启保留'),
      ],
    ),
  );
}

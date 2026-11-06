import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'appearance.dart';
import 'brand.dart';
import 'glass.dart';
import 'personal_space.dart';
import 'state.dart' show demo, ink, muted, green, sceneInk, sceneMuted;
import 'widgets.dart';
import 'skymoni_glass.dart';
import 'cloud_assistant.dart';

const personalModuleNames = ['对话', '今天', '任务', '记忆', '小云'];
const _moduleIcons = [
  Icons.chat_bubble_outline,
  Icons.calendar_today_outlined,
  Icons.checklist_rounded,
  Icons.auto_stories_outlined,
  Icons.cloud_outlined,
];

class PersonalModuleBar extends StatefulWidget {
  const PersonalModuleBar({
    super.key,
    required this.selected,
    required this.onSelected,
  });
  final int selected;
  final ValueChanged<int> onSelected;
  @override
  State<PersonalModuleBar> createState() => _PersonalModuleBarState();
}

class _PersonalModuleBarState extends State<PersonalModuleBar>
    with TickerProviderStateMixin {
  late final AnimationController _position;
  late final AnimationController _stretch;
  late final Listenable _motion;
  bool get _reduced =>
      MediaQuery.disableAnimationsOf(context) ||
      appearance.flag('reduceMotion') ||
      (demo.prefs['减少动态效果'] ?? false);

  Widget _dockSurface(Widget child) => GlassSurface(
    key: const ValueKey('main-module-dock-surface'),
    skymoni: true,
    radius: 29,
    liquid: true,
    opacity: .13,
    liquidOpacity: .13,
    liquidBlur: appearance.number('inputBlur'),
    skymoniKind: SkymoniGlassKind.navigation,
    child: child,
  );

  @override
  void initState() {
    super.initState();
    _position = AnimationController.unbounded(
      vsync: this,
      value: widget.selected.toDouble(),
    );
    _stretch = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
      value: 1,
    );
    _motion = Listenable.merge([_position, _stretch]);
  }

  void _jump() {
    _position.stop();
    _position.value = widget.selected.toDouble();
    _stretch.stop();
    _stretch.value = 1;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_reduced) _jump();
  }

  @override
  void didUpdateWidget(PersonalModuleBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_reduced) {
      _jump();
      return;
    }
    if (oldWidget.selected == widget.selected) return;
    // Match Skymoni's existing glass navigation spring and 280 ms stretch.
    _position.animateWith(
      SpringSimulation(
        const SpringDescription(mass: .85, stiffness: 300, damping: 26),
        _position.value,
        widget.selected.toDouble(),
        _position.velocity,
      ),
    );
    _stretch.forward(from: 0);
  }

  @override
  void dispose() {
    _position.dispose();
    _stretch.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 2),
    // The composer owns one shared horizontal inset for both floating frames.
    child: SizedBox(
      width: double.infinity,
      height: 56,
      child: _dockSurface(
        LayoutBuilder(
          builder: (context, bounds) {
            final cell = (bounds.maxWidth - 8) / personalModuleNames.length;
            return Stack(
              clipBehavior: Clip.none,
              children: [
                AnimatedBuilder(
                  animation: _motion,
                  builder: (context, _) => Positioned(
                    left: 4 + cell * _position.value,
                    top: 4,
                    bottom: 4,
                    width: cell,
                    child: IgnorePointer(
                      child: Transform.scale(
                        scaleX:
                            1 +
                            .06 *
                                (1 -
                                    Curves.easeOutCubic.transform(
                                      _stretch.value,
                                    )),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(25),
                            boxShadow: const [
                              BoxShadow(
                                color: Color(0x12142839),
                                blurRadius: 7,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: GlassSurface(
                            key: const ValueKey('main-module-moving-lens'),
                            skymoni: true,
                            skymoniKind: SkymoniGlassKind.navigation,
                            radius: 25,
                            liquid: true,
                            liquidBlur: appearance.number('inputBlur'),
                            opacity: .13,
                            liquidOpacity: .13,
                            child: Container(
                              key: const ValueKey('main-module-selection-body'),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(25),
                                border: appearance.flag('skymoniGlass')
                                    ? null
                                    : Border.all(
                                        color: Colors.white.withValues(
                                          alpha: demo.dark ? .22 : .75,
                                        ),
                                        width: .85,
                                      ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(4),
                  child: Row(
                    children: [
                      for (var i = 0; i < personalModuleNames.length; i++)
                        Expanded(
                          child: _PersonalModuleItem(
                            key: ValueKey('main-module-$i'),
                            index: i,
                            selected: widget.selected == i,
                            onTap: () => widget.onSelected(i),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    ),
  );
}

class _PersonalModuleItem extends StatelessWidget {
  const _PersonalModuleItem({
    super.key,
    required this.index,
    required this.selected,
    required this.onTap,
  });
  final int index;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Semantics(
    selected: selected,
    button: true,
    label: personalModuleNames[index],
    excludeSemantics: true,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(25),
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      focusColor: green.withValues(alpha: .1),
      child: Builder(
        builder: (context) {
          final color = selected
              ? green
              : appearance.flag('skymoniGlass')
              ? ink
              : muted;
          return Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(_moduleIcons[index], size: 21, color: color),
              const SizedBox(height: 2),
              Text(
                personalModuleNames[index],
                maxLines: 1,
                style: TextStyle(
                  fontSize: 9,
                  height: 12 / 9,
                  color: color,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
}

/// A distinct readable layer inside the existing translucent composer shell.
/// The scene remains Skivu's current wallpaper and optical engine.
class MainComposerInputSurface extends StatelessWidget {
  const MainComposerInputSurface({super.key, required this.child});
  final Widget child;
  bool get _lightText =>
      appearance.textColor('inputText').computeLuminance() > .45;
  @override
  Widget build(BuildContext context) {
    final padded = Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 3, 4),
      child: child,
    );
    if (appearance.flag('skymoniGlass') && SkymoniGlassProgram.available) {
      return SkymoniGlassSurface(
        key: const ValueKey('main-composer-input-surface'),
        radius: 26,
        dark: _lightText,
        kind: SkymoniGlassKind.readable,
        child: padded,
      );
    }
    return ConfigurableGlassSurface(
      area: 'inputBlur',
      radius: appearance.flag('floatingInput') ? 26 : 0,
      child: DecoratedBox(
        key: const ValueKey('main-composer-input-surface'),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(26),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: _lightText
                ? [
                    const Color(0xff26364e).withValues(alpha: .76),
                    const Color(0xff18283e).withValues(alpha: .62),
                  ]
                : [
                    Colors.white.withValues(alpha: .86),
                    Colors.white.withValues(alpha: .65),
                  ],
          ),
          border: Border.all(
            color: Colors.white.withValues(alpha: _lightText ? .26 : .94),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: const Color(0xff233344).withValues(alpha: .035),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: padded,
      ),
    );
  }
}

class PersonalModulePage extends StatefulWidget {
  const PersonalModulePage({
    super.key,
    required this.module,
    required this.bottomInset,
    required this.topInset,
    required this.onDraft,
    required this.onModule,
    this.store,
  });
  final int module;
  final double bottomInset, topInset;
  final ValueChanged<String> onDraft;
  final ValueChanged<int> onModule;
  final PersonalSpaceStore? store;
  @override
  State<PersonalModulePage> createState() => _PersonalModulePageState();
}

class _PersonalModulePageState extends State<PersonalModulePage> {
  PersonalSpaceStore get store => widget.store ?? personalSpace;
  bool scheduled = false;
  String? category;
  Future<void> act(Future<void> Function() fn) async {
    try {
      await fn();
    } catch (_) {
      if (mounted) toast(context, '保存未完成，原有记录已保留。请重试。');
    }
  }

  void edit({bool memory = false, PersonalRecord? record, String date = ''}) =>
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: Colors.transparent,
        builder: (_) => _RecordEditor(
          store: store,
          memory: memory,
          record: record,
          date: date,
        ),
      );
  Widget box(List<Widget> children, {double padding = 18}) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: GlassSurface(
      opacity: .44,
      radius: 24,
      child: Padding(
        padding: EdgeInsets.all(padding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      ),
    ),
  );
  Widget title(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(5, 15, 5, 11),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w600,
        color: sceneInk,
      ),
    ),
  );
  Widget note(String text) =>
      Text(text, style: TextStyle(fontSize: 12, height: 1.8, color: muted));
  Widget link(String text, VoidCallback fn) => TextButton(
    onPressed: fn,
    style: TextButton.styleFrom(
      padding: EdgeInsets.zero,
      alignment: Alignment.centerLeft,
    ),
    child: Text(text, style: TextStyle(fontSize: 12, color: green)),
  );
  Widget meta(IconData icon, String text) => Row(
    children: [
      Icon(icon, size: 15, color: green),
      const SizedBox(width: 7),
      Text(text, style: TextStyle(fontSize: 11, color: green)),
    ],
  );
  Widget taskRow(PersonalRecord r) => Row(
    children: [
      SizedBox(
        width: 34,
        child: Checkbox(
          value: r.done,
          shape: const CircleBorder(),
          activeColor: green,
          onChanged: (_) => act(() => store.toggle(r.id)),
        ),
      ),
      Expanded(
        child: InkWell(
          onTap: () => edit(record: r),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  r.title,
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.6,
                    color: r.done ? muted : ink,
                    decoration: r.done ? TextDecoration.lineThrough : null,
                  ),
                ),
                if (r.date.isNotEmpty)
                  Text(
                    '${r.date == personalDay() ? '今天' : r.date}${r.time.isEmpty ? '' : ' · ${r.time}'}',
                    style: TextStyle(fontSize: 10, color: muted),
                  ),
              ],
            ),
          ),
        ),
      ),
    ],
  );
  List<Widget> today() {
    final due = store.tasks.where((r) => r.date == personalDay()).toList()
      ..sort(
        (a, b) => (a.time.isEmpty ? '99:99' : a.time).compareTo(
          b.time.isEmpty ? '99:99' : b.time,
        ),
      );
    final pending = due.where((r) => !r.done).toList(),
        done = due.where((r) => r.done).length;
    final memories = store.memories.toList()
      ..sort((a, b) => b.updated.compareTo(a.updated));
    return [
      Text(
        '${DateTime.now().month}月${DateTime.now().day}日 · 把日子过成自己的节奏',
        style: TextStyle(fontSize: 12, height: 1.8, color: sceneMuted),
      ),
      const SizedBox(height: 12),
      box([
        meta(Icons.calendar_today_outlined, '今日安排'),
        const SizedBox(height: 14),
        if (pending.isEmpty) ...[
          Text(
            '留一点空间给今天',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w500,
              color: ink,
            ),
          ),
          const SizedBox(height: 8),
          note('还没有待办安排。写下一件想做的小事吧。'),
          link('添加今日安排 ＋', () => edit(date: personalDay())),
        ] else ...[
          Container(
            padding: const EdgeInsets.fromLTRB(13, 12, 12, 9),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: .3),
              border: Border(left: BorderSide(color: green, width: 3)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  pending.first.title,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                    color: ink,
                  ),
                ),
                const SizedBox(height: 5),
                note(
                  pending.first.time.isEmpty ? '按自己的节奏' : pending.first.time,
                ),
                if (pending.first.body.isNotEmpty) note(pending.first.body),
                link(
                  '和小云聊聊',
                  () => widget.onDraft(
                    '帮我准备「${pending.first.title}」${pending.first.body.isEmpty ? '' : '：${pending.first.body}'}',
                  ),
                ),
              ],
            ),
          ),
          for (final r in pending.skip(1).take(2)) taskRow(r),
          if (done > 0) ...[const SizedBox(height: 10), note('已完成 $done 件小事')],
        ],
      ]),
      box([
        meta(Icons.auto_awesome_outlined, '一点点，也很好'),
        const SizedBox(height: 18),
        RichText(
          text: TextSpan(
            style: TextStyle(color: ink),
            children: [
              TextSpan(text: '$done', style: const TextStyle(fontSize: 32)),
              TextSpan(
                text: '  件小事已完成',
                style: TextStyle(color: muted, fontSize: 12),
              ),
            ],
          ),
        ),
        const SizedBox(height: 15),
        ClipRRect(
          borderRadius: BorderRadius.circular(5),
          child: LinearProgressIndicator(
            value: due.isEmpty ? 0 : done / due.length,
            minHeight: 6,
            color: green.withValues(alpha: .6),
            backgroundColor: green.withValues(alpha: .08),
          ),
        ),
        const SizedBox(height: 17),
        Row(
          children: [
            Expanded(
              child: note('全部待办\n${store.tasks.where((r) => !r.done).length}'),
            ),
            Expanded(child: note('记住的小事\n${memories.length}')),
          ],
        ),
      ]),
      if (memories.isNotEmpty)
        box([
          meta(Icons.auto_stories_outlined, '最近记住的'),
          const SizedBox(height: 10),
          Text(
            memories.first.title,
            style: TextStyle(fontSize: 15, color: ink),
          ),
          const SizedBox(height: 6),
          note(memories.first.body),
          link('去看看 ↗', () => widget.onModule(3)),
        ]),
    ];
  }

  List<Widget> tasks() {
    final all = store.tasks
        .where((r) => !scheduled || r.time.isNotEmpty)
        .toList();
    final day = personalDay();
    final groups = <String, List<PersonalRecord>>{
      '今天': all.where((r) => !r.done && r.date == day).toList(),
      '之前的安排': all
          .where(
            (r) => !r.done && r.date.isNotEmpty && r.date.compareTo(day) < 0,
          )
          .toList(),
      '接下来': all.where((r) => !r.done && r.date.compareTo(day) > 0).toList(),
      '未定日期': all.where((r) => !r.done && r.date.isEmpty).toList(),
      '已完成': all.where((r) => r.done).toList(),
    };
    return [
      Row(
        children: [
          for (final flag in [false, true])
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: ChoiceChip(
                  label: Center(child: Text(flag ? '定时' : '任务')),
                  selected: scheduled == flag,
                  onSelected: (_) => setState(() => scheduled = flag),
                ),
              ),
            ),
        ],
      ),
      if (scheduled)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(
            '查看有时间的安排；当前不会在后台触发系统提醒。',
            style: TextStyle(fontSize: 12, height: 1.8, color: sceneMuted),
          ),
        ),
      if (all.isEmpty) ...[
        const SizedBox(height: 22),
        box([
          Text('把想做的事，放在这里', style: TextStyle(fontSize: 17, color: ink)),
          const SizedBox(height: 9),
          note('研究、规划或创作，从一件小事开始。'),
          link('添加任务 ＋', () => edit()),
        ]),
      ],
      for (final e in groups.entries)
        if (e.value.isNotEmpty) ...[
          title(e.key),
          box([
            for (final r
                in (e.value..sort(
                  (a, b) => (a.date + a.time).compareTo(b.date + b.time),
                )))
              taskRow(r),
          ], padding: 10),
        ],
    ];
  }

  List<Widget> memories() {
    final all = store.memories.toList()
      ..sort((a, b) => b.updated.compareTo(a.updated));
    final categories = all.map((r) => r.category).toSet();
    return [
      box([
        Icon(
          Icons.workspace_premium_outlined,
          size: 20,
          color: const Color(0xffe9a05f),
        ),
        const SizedBox(height: 8),
        Text(
          '我所记住的你',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w500,
            color: ink,
          ),
        ),
        const SizedBox(height: 6),
        note(all.isEmpty ? '从你愿意分享的事开始' : '记录了 ${all.length} 件小事'),
        const Divider(height: 22),
        note(
          all.isEmpty
              ? '喜欢什么、想去哪里、习惯怎样的节奏……\n把愿意记住的事，亲手放在这里。'
              : all.take(3).map((r) => r.body).join('\n\n'),
        ),
        link('添加一条记忆 ＋', () => edit(memory: true)),
      ]),
      title('全部记忆'),
      if (categories.isNotEmpty)
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final c in categories)
              ActionChip(
                avatar: Icon(Icons.folder_outlined, size: 17, color: green),
                label: Text('$c · ${all.where((r) => r.category == c).length}'),
                onPressed: () =>
                    setState(() => category = category == c ? null : c),
              ),
          ],
        ),
      if (category != null) link('查看全部', () => setState(() => category = null)),
      const SizedBox(height: 13),
      for (final r in all.where(
        (r) => category == null || r.category == category,
      ))
        box([
          Row(
            children: [
              Expanded(
                child: Text(
                  r.title,
                  style: TextStyle(fontSize: 15, color: ink),
                ),
              ),
              IconButton(
                tooltip: '编辑记忆',
                onPressed: () => edit(memory: true, record: r),
                icon: Icon(Icons.edit_outlined, size: 18, color: muted),
              ),
            ],
          ),
          note(r.category),
          const SizedBox(height: 7),
          note(r.body),
          link(
            '带到对话 ↗',
            () => widget.onDraft('我记录了一件事：${r.title}\n${r.body}\n\n想和你聊聊。'),
          ),
        ]),
      if (all.isEmpty) box([note('这里由你亲手记录和管理，不会自动扫描原有聊天。')]),
    ];
  }

  List<Widget> cloud() => [
    const SizedBox(height: 15),
    Center(
      child: Column(
        children: [
          const BrandMark(size: 70),
          const SizedBox(height: 16),
          Text('小云', style: TextStyle(fontSize: 27, color: sceneInk)),
          const SizedBox(height: 8),
          Text(
            '把想法放在这里，\n我们从一件小事开始。',
            style: TextStyle(fontSize: 12, height: 1.8, color: sceneMuted),
          ),
        ],
      ),
    ),
    const SizedBox(height: 27),
    const CloudAssistantPane(),
    Row(
      children: [
        for (final i in [2, 3])
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(
                right: i == 2 ? 6 : 0,
                left: i == 3 ? 6 : 0,
              ),
              child: InkWell(
                onTap: () => widget.onModule(i),
                child: box([
                  Icon(_moduleIcons[i], color: green),
                  const SizedBox(height: 11),
                  Text(
                    personalModuleNames[i],
                    style: TextStyle(fontSize: 15, color: ink),
                  ),
                  const SizedBox(height: 6),
                  note(
                    i == 2
                        ? '${store.tasks.where((r) => !r.done).length} 项待办'
                        : '${store.memories.length} 条记录',
                  ),
                ]),
              ),
            ),
          ),
      ],
    ),
    if (store.archivedTasks.isNotEmpty || store.archivedMemories.isNotEmpty)
      link('回收站', recycle),
  ];
  void recycle() => showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    builder: (context) => AnimatedBuilder(
      animation: store,
      builder: (context, _) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.all(20),
        children: [
          const Text('回收站', style: TextStyle(fontSize: 20)),
          for (final memory in [false, true])
            for (final r
                in memory ? store.archivedMemories : store.archivedTasks)
              ListTile(
                title: Text(r.title),
                trailing: TextButton(
                  child: const Text('恢复'),
                  onPressed: () => act(
                    () => store.archive(r.id, memory: memory, archived: false),
                  ),
                ),
              ),
        ],
      ),
    ),
  );
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: store,
    builder: (context, _) => ListView(
      key: PageStorageKey('main-personal-module-${widget.module}'),
      padding: EdgeInsets.fromLTRB(15, widget.topInset, 15, widget.bottomInset),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                personalModuleNames[widget.module],
                style: TextStyle(
                  fontSize: 29,
                  fontWeight: FontWeight.w400,
                  color: sceneInk,
                ),
              ),
            ),
            if (widget.module < 4)
              IconButton(
                tooltip: widget.module == 3 ? '添加记忆' : '添加任务',
                onPressed: () => edit(
                  memory: widget.module == 3,
                  date: widget.module == 1 ? personalDay() : '',
                ),
                icon: Icon(
                  widget.module == 3 ? Icons.library_add_outlined : Icons.add,
                  color: sceneInk,
                ),
              ),
          ],
        ),
        const SizedBox(height: 18),
        if (store.error != null)
          note(store.error!)
        else
          ...switch (widget.module) {
            1 => today(),
            2 => tasks(),
            3 => memories(),
            _ => cloud(),
          },
      ],
    ),
  );
}

class _RecordEditor extends StatefulWidget {
  const _RecordEditor({
    required this.store,
    required this.memory,
    this.record,
    this.date = '',
  });
  final PersonalSpaceStore store;
  final bool memory;
  final PersonalRecord? record;
  final String date;
  @override
  State<_RecordEditor> createState() => _RecordEditorState();
}

class _RecordEditorState extends State<_RecordEditor> {
  late final title = TextEditingController(text: widget.record?.title ?? '');
  late final body = TextEditingController(text: widget.record?.body ?? '');
  late final category = TextEditingController(
    text: widget.record?.category ?? '生活',
  );
  late String date = widget.record?.date ?? widget.date,
      time = widget.record?.time ?? '';
  bool pending = false;
  String? error;
  @override
  void dispose() {
    title.dispose();
    body.dispose();
    category.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (pending) return;
    setState(() {
      pending = true;
      error = null;
    });
    try {
      await widget.store.save(
        memory: widget.memory,
        id: widget.record?.id,
        title: title.text,
        body: body.text,
        date: date,
        time: time,
        category: category.text,
      );
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted)
        setState(() {
          pending = false;
          error = '保存未完成，请检查标题、内容、日期后重试。';
        });
    }
  }

  Future<void> archive() async {
    if (pending) return;
    setState(() => pending = true);
    try {
      await widget.store.archive(widget.record!.id, memory: widget.memory);
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted)
        setState(() {
          pending = false;
          error = '暂时无法移到回收站，请重试。';
        });
    }
  }

  Future<void> pickDate() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: DateTime.tryParse(date) ?? now,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (d != null && mounted) setState(() => date = personalDay(d));
  }

  Future<void> pickTime() async {
    final selected = await showTimePicker(
      context: context,
      initialTime: time.isEmpty
          ? TimeOfDay.now()
          : TimeOfDay(
              hour: int.parse(time.split(':')[0]),
              minute: int.parse(time.split(':')[1]),
            ),
    );
    if (selected != null && mounted)
      setState(() {
        date = date.isEmpty ? personalDay() : date;
        time =
            '${selected.hour.toString().padLeft(2, '0')}:${selected.minute.toString().padLeft(2, '0')}';
      });
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(
      12,
      8,
      12,
      MediaQuery.viewInsetsOf(context).bottom + 12,
    ),
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .85,
      ),
      child: GlassSurface(
        opacity: .94,
        radius: 26,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${widget.record == null ? '添加' : '编辑'}${widget.memory ? '记忆' : '任务'}',
                      style: TextStyle(fontSize: 20, color: ink),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: pending ? null : () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: title,
                enabled: !pending,
                maxLength: 160,
                decoration: InputDecoration(
                  labelText: widget.memory ? '记忆标题' : '任务名称',
                  counterText: '',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: body,
                enabled: !pending,
                maxLength: 12000,
                minLines: 3,
                maxLines: 6,
                decoration: InputDecoration(
                  labelText: widget.memory ? '内容' : '补充说明',
                  counterText: '',
                ),
              ),
              if (widget.memory) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: category,
                  enabled: !pending,
                  maxLength: 40,
                  decoration: const InputDecoration(
                    labelText: '分类',
                    counterText: '',
                  ),
                ),
              ] else ...[
                const SizedBox(height: 12),
                Wrap(
                  spacing: 9,
                  children: [
                    TextButton.icon(
                      onPressed: pending ? null : pickDate,
                      icon: const Icon(Icons.calendar_today_outlined, size: 17),
                      label: Text(date.isEmpty ? '选择日期' : date),
                    ),
                    TextButton.icon(
                      onPressed: pending ? null : pickTime,
                      icon: const Icon(Icons.schedule, size: 17),
                      label: Text(time.isEmpty ? '选择时间' : time),
                    ),
                    if (date.isNotEmpty)
                      TextButton(
                        onPressed: pending
                            ? null
                            : () => setState(() {
                                date = '';
                                time = '';
                              }),
                        child: const Text('清除时间'),
                      ),
                  ],
                ),
              ],
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                      fontSize: 12,
                    ),
                  ),
                ),
              const SizedBox(height: 18),
              Row(
                children: [
                  if (widget.record != null)
                    TextButton(
                      onPressed: pending ? null : archive,
                      child: const Text('移到回收站'),
                    ),
                  const Spacer(),
                  FilledButton(
                    onPressed: pending ? null : save,
                    child: Text(pending ? '正在保存…' : '保存'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

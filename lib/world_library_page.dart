import 'package:flutter/material.dart';
import 'companion_library.dart';
import 'state.dart';
import 'widgets.dart';

class WorldLibraryPage extends StatefulWidget {
  const WorldLibraryPage({super.key});
  @override
  State<WorldLibraryPage> createState() => _WorldLibraryPageState();
}

class _WorldLibraryPageState extends State<WorldLibraryPage> {
  String? selected;
  String query = '';
  Future<void> editWorld([WorldSetting? world]) async {
    if (world == null && demo.worlds.length >= 200) {
      toast(context, '最多保存200个世界观。');
      return;
    }
    final name = TextEditingController(text: world?.name ?? '');
    final category = TextEditingController(text: world?.category ?? '未分类');
    final summary = TextEditingController(text: world?.summary ?? '');
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(world == null ? '新建世界观' : '编辑世界观'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                maxLength: 80,
                decoration: const InputDecoration(labelText: '名称'),
              ),
              TextField(
                controller: category,
                maxLength: 40,
                decoration: const InputDecoration(
                  labelText: '分类',
                  hintText: '如现代、奇幻、科幻',
                ),
              ),
              TextField(
                controller: summary,
                minLines: 3,
                maxLines: 8,
                maxLength: 20000,
                decoration: const InputDecoration(labelText: '世界概览'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (name.text.trim().isNotEmpty) Navigator.pop(c, true);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (yes == true && mounted) {
      if (world == null) {
        world = WorldSetting(id: libraryId('world'), name: name.text.trim());
        demo.worlds.add(world);
        selected = world.id;
      }
      world.name = name.text.trim();
      world.category = category.text.trim().isEmpty
          ? '未分类'
          : category.text.trim();
      world.summary = summary.text.trim();
      demo.saveLibrary();
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    name.dispose();
    category.dispose();
    summary.dispose();
  }

  Future<void> editEntry(
    WorldSetting world,
    bool scene, [
    WorldEntry? entry,
  ]) async {
    if (entry == null && world.entries.length >= 100) {
      toast(context, '每个世界观最多100条设定与场景。');
      return;
    }
    final name = TextEditingController(text: entry?.name ?? '');
    final category = TextEditingController(
      text: entry?.category ?? (scene ? '日常' : '基本规则'),
    );
    final content = TextEditingController(text: entry?.content ?? '');
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(scene ? '场景设定' : '世界观条目'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                maxLength: 80,
                decoration: const InputDecoration(labelText: '名称'),
              ),
              TextField(
                controller: category,
                maxLength: 40,
                decoration: InputDecoration(
                  labelText: '详细分类',
                  hintText: scene ? '如日常、冒险、特殊事件' : '如地理、历史、势力、规则、文化',
                ),
              ),
              TextField(
                controller: content,
                minLines: 3,
                maxLines: 9,
                maxLength: 12000,
                decoration: const InputDecoration(labelText: '详细内容'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (name.text.trim().isNotEmpty) Navigator.pop(c, true);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (yes == true && mounted && demo.worlds.contains(world)) {
      if (entry == null) {
        entry = WorldEntry(
          id: libraryId('entry'),
          name: '',
          category: '',
          content: '',
          scene: scene,
        );
        world.entries.add(entry);
      }
      entry.name = name.text.trim();
      entry.category = category.text.trim().isEmpty
          ? '未分类'
          : category.text.trim();
      entry.content = content.text.trim();
      demo.saveLibrary();
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    name.dispose();
    category.dispose();
    content.dispose();
  }

  Future<void> remove(WorldSetting world, [WorldEntry? entry]) async {
    final count = demo.personas
        .where(
          (p) =>
              p.worldId == world.id && (entry == null || p.sceneId == entry.id),
        )
        .length;
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('删除${entry?.name ?? world.name}？'),
        content: Text('$count 个角色的关联会解除，聊天记录保留。删除后无法恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (yes == true && mounted) {
      if (entry == null) {
        demo.removeWorld(world.id);
        setState(() => selected = null);
      } else {
        demo.removeWorldEntry(world, entry.id);
      }
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: demo,
    builder: (context, _) {
      final world = demo.worlds.where((w) => w.id == selected).firstOrNull;
      if (world != null) {
        final bound = demo.personas.where((p) => p.worldId == world.id).length;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextButton.icon(
              onPressed: () => setState(() => selected = null),
              icon: const Icon(Icons.arrow_back),
              label: const Text('全部世界观'),
            ),
            PageHeading(
              world.category,
              world.name,
              '$bound 个角色共用 · 修改后用于接下来的对话',
            ),
            Pane(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    world.summary.isEmpty ? '添加世界概览，让角色了解这个世界。' : world.summary,
                    style: const TextStyle(height: 1.7),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    children: [
                      TextButton.icon(
                        onPressed: () => editWorld(world),
                        icon: const Icon(Icons.edit_outlined),
                        label: const Text('编辑概览'),
                      ),
                      TextButton.icon(
                        onPressed: () => remove(world),
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('删除世界观'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            for (final scene in [false, true]) ...[
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: label(
                      scene ? '场景' : '世界观详细分类',
                      size: 18,
                      weight: FontWeight.w600,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () => editEntry(world, scene),
                    icon: const Icon(Icons.add),
                    label: Text(scene ? '添加场景' : '添加条目'),
                  ),
                ],
              ),
              if (!world.entries.any((e) => e.scene == scene))
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(scene ? '场景可在角色卡中单独选择。' : '按地理、历史、势力、规则等分类添加设定。'),
                ),
              for (final category
                  in world.entries
                      .where((e) => e.scene == scene)
                      .map((e) => e.category)
                      .toSet()) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  child: label(category, size: 13),
                ),
                Pane(
                  padding: const EdgeInsets.all(6),
                  child: Column(
                    children: [
                      for (final entry in world.entries.where(
                        (e) => e.scene == scene && e.category == category,
                      ))
                        ListTile(
                          title: Text(entry.name),
                          subtitle: Text(
                            entry.content.isEmpty ? '尚未填写详细内容' : entry.content,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () => editEntry(world, scene, entry),
                          trailing: IconButton(
                            tooltip: '删除${entry.name}',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => remove(world, entry),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ],
          ],
        );
      }
      final values = demo.worlds
          .where(
            (w) => '${w.name} ${w.category} ${w.summary}'
                .toLowerCase()
                .contains(query.toLowerCase()),
          )
          .toList();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PageHeading('共用设定', '世界观', '建立一个世界，让多位角色共享背景，并分别选择场景。'),
          FilledButton.icon(
            onPressed: () => editWorld(),
            icon: const Icon(Icons.add),
            label: const Text('新建世界观'),
          ),
          const SizedBox(height: 16),
          TextField(
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: '搜索世界观或分类',
            ),
            onChanged: (v) => setState(() => query = v),
          ),
          if (values.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('还没有世界观。创建后即可在角色卡中选择。', textAlign: TextAlign.center),
            ),
          for (final category in values.map((w) => w.category).toSet()) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: label(category, size: 14),
            ),
            for (final world in values.where((w) => w.category == category))
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Pane(
                  padding: const EdgeInsets.all(4),
                  child: ListTile(
                    leading: const Icon(Icons.public_outlined),
                    title: Text(world.name),
                    subtitle: Text(
                      '${world.entries.where((e) => !e.scene).length} 条设定 · ${world.scenes.length} 个场景 · ${demo.personas.where((p) => p.worldId == world.id).length} 个角色',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => setState(() => selected = world.id),
                  ),
                ),
              ),
          ],
        ],
      );
    },
  );
}

Future<void> manageWorldLibrary(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => SizedBox(
        height: MediaQuery.sizeOf(context).height * .86,
        child: const SingleChildScrollView(
          padding: EdgeInsets.all(18),
          child: WorldLibraryPage(),
        ),
      ),
    );

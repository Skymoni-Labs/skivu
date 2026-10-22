import 'package:flutter/material.dart';
import 'state.dart';
import 'widgets.dart';

class WorkspacePanel extends StatefulWidget {
  const WorkspacePanel({super.key, required this.close});
  final VoidCallback close;
  @override
  State<WorkspacePanel> createState() => _WorkspacePanelState();
}

class _WorkspacePanelState extends State<WorkspacePanel> {
  int tab = 0;
  String file = '灵感笔记.md';
  bool folder = true, ran = false;
  final command = TextEditingController();
  final note = TextEditingController(text: demo.workspaceDraft);
  @override
  void dispose() {
    command.dispose();
    note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(22, 24, 18, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              label('工作区', size: 18, weight: FontWeight.w600),
              const SizedBox(width: 10),
              const TinyTag('本地演示'),
              const Spacer(),
              IconButton(
                tooltip: '关闭工作区',
                onPressed: widget.close,
                icon: const Icon(Icons.close, size: 19),
              ),
            ],
          ),
          label('想法和行动，在同一个地方。', size: 11, color: muted),
          const SizedBox(height: 24),
          Row(
            children: [
              for (final (i, icon, title) in [
                (0, Icons.folder_outlined, '文件'),
                (1, Icons.handyman_outlined, '工具'),
                (2, Icons.language, '浏览器'),
                (3, Icons.terminal, '终端'),
              ])
                Expanded(
                  child: InkWell(
                    onTap: () => setState(() => tab = i),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            color: tab == i
                                ? green
                                : muted.withValues(alpha: .18),
                            width: tab == i ? 2 : 1,
                          ),
                        ),
                      ),
                      child: Column(
                        children: [
                          Icon(icon, size: 18, color: tab == i ? green : muted),
                          const SizedBox(height: 6),
                          label(
                            title,
                            size: 10,
                            color: tab == i ? green : muted,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 20),
          Expanded(
            child: switch (tab) {
              0 => files(),
              1 => tools(),
              2 => browser(),
              _ => terminal(),
            },
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              const Icon(Icons.lock_outline, size: 12, color: muted),
              const SizedBox(width: 6),
              Expanded(child: label('与真实文件、网络和系统完全隔离', size: 9, color: muted)),
            ],
          ),
        ],
      ),
    ),
  );
  Widget files() => ListView(
    children: [
      InkWell(
        onTap: () => setState(() => folder = !folder),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            children: [
              Icon(folder ? Icons.expand_more : Icons.chevron_right, size: 16),
              const SizedBox(width: 6),
              Icon(Icons.folder_outlined, size: 17, color: green),
              const SizedBox(width: 8),
              Flexible(child: label('ski / ${demo.workspaceName}', size: 12)),
            ],
          ),
        ),
      ),
      if (folder) ...[
        for (final name in ['灵感笔记.md', '本周计划.txt', '关于此空间.md'])
          InkWell(
            onTap: () => setState(() => file = name),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
              decoration: BoxDecoration(
                color: file == name ? green.withValues(alpha: .08) : null,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.description_outlined,
                    size: 15,
                    color: muted,
                  ),
                  const SizedBox(width: 9),
                  label(name, size: 11, color: file == name ? green : null),
                ],
              ),
            ),
          ),
      ],
      const SizedBox(height: 24),
      Row(
        children: [
          const Icon(Icons.notes, size: 16, color: muted),
          const SizedBox(width: 8),
          label(file, size: 11),
          const Spacer(),
          const TinyTag('内存'),
        ],
      ),
      const SizedBox(height: 12),
      Pane(
        padding: const EdgeInsets.all(15),
        child: file == '灵感笔记.md'
            ? TextField(
                controller: note,
                maxLines: 15,
                style: const TextStyle(fontSize: 12, height: 1.9),
                decoration: const InputDecoration(
                  filled: false,
                  contentPadding: EdgeInsets.zero,
                  border: InputBorder.none,
                ),
                onChanged: (value) {
                  if (demo.prefs['草稿自动保留'] ?? true) demo.workspaceDraft = value;
                },
              )
            : label(
                file == '本周计划.txt'
                    ? 'MON  聚焦目标\nTUE  创意草稿\nWED  安静工作\nTHU  交流想法\nFRI  回顾与收束'
                    : '这个空间用于体验文件树与预览。\n\n所有文件都来自本地示例字符串，不会读取磁盘。草稿按设置保留在当前会话内存，刷新后重置。',
                size: 12,
                height: 2,
              ),
      ),
    ],
  );
  Widget tools() => ListView(
    children: [
      label('可用工具', size: 12, color: muted),
      const SizedBox(height: 12),
      for (final (title, icon) in [
        ('笔记整理', Icons.edit_note),
        ('计划拆解', Icons.checklist),
        ('文件摘要', Icons.summarize_outlined),
      ])
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Pane(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(icon, color: green, size: 20),
                    const SizedBox(width: 10),
                    label(title, size: 13),
                    const Spacer(),
                    const TinyTag('模拟'),
                  ],
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: () => showDialog(
                      context: context,
                      builder: (c) => AlertDialog(
                        title: Text('$title · 演示结果'),
                        content: const Text(
                          '1. 明确目标\n2. 列出下一步行动\n3. 安排一次回顾\n\n这是预置的演示结果，没有调用任何工具。',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(c),
                            child: const Text('完成'),
                          ),
                        ],
                      ),
                    ),
                    child: const Text('运行演示'),
                  ),
                ),
              ],
            ),
          ),
        ),
    ],
  );
  Widget browser() => ListView(
    children: [
      Pane(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            const Icon(Icons.lock_outline, size: 15, color: muted),
            const SizedBox(width: 8),
            Expanded(child: label('ski.demo / inspiration', size: 11)),
            const Icon(Icons.refresh, size: 15, color: muted),
          ],
        ),
      ),
      const SizedBox(height: 16),
      Pane(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const TinyTag('静态浏览器画布'),
            const SizedBox(height: 28),
            label(
              '让灵感\n自然发生。',
              size: 28,
              color: green,
              weight: FontWeight.w600,
            ),
            const SizedBox(height: 20),
            Container(
              height: 105,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xffd3e1c9), Color(0xffeae5d5)],
                ),
                borderRadius: BorderRadius.circular(60),
              ),
              child: Center(
                child: Icon(Icons.spa_outlined, size: 42, color: green),
              ),
            ),
            const SizedBox(height: 22),
            label('这不是实际网页。点击下方按钮，体验页面内导航。', size: 12, color: muted),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: () => showDialog(
                context: context,
                builder: (c) => AlertDialog(
                  title: const Text('一份灵感清单'),
                  content: const Text(
                    '观察窗外的一棵树。\n给自己写一封短信。\n从没走过的路回家。\n\n本内容为 ski 自主编写的示例。',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(c),
                      child: const Text('收好灵感'),
                    ),
                  ],
                ),
              ),
              child: const Text('打开灵感清单'),
            ),
          ],
        ),
      ),
    ],
  );
  Widget terminal() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      label('沙盒终端', size: 13, weight: FontWeight.w600),
      const SizedBox(height: 10),
      label('输入任何内容只会返回固定示例，不执行命令。', size: 11, color: muted),
      const SizedBox(height: 15),
      Expanded(
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: ink,
            borderRadius: BorderRadius.circular(12),
          ),
          child: SelectableText(
            'ski sandbox · demo only\n\n\$ help\n可用示例：help / ls / status\n\n${ran ? '> ${command.text}\n[模拟] 工作区就绪 · 3 个示例文件\n没有执行系统命令。' : '等待你的第一条演示指令…'}',
            style: const TextStyle(
              fontFamily: 'SkiSans',
              color: Color(0xffbfd5c5),
              fontSize: 11,
              height: 2,
            ),
          ),
        ),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: command,
        decoration: InputDecoration(
          hintText: '输入演示指令',
          suffixIcon: IconButton(
            tooltip: '运行模拟指令',
            onPressed: () => setState(() => ran = true),
            icon: const Icon(Icons.arrow_forward, size: 18),
          ),
        ),
        onSubmitted: (_) => setState(() => ran = true),
      ),
    ],
  );
}

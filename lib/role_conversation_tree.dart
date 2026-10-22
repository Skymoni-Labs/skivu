import 'package:flutter/material.dart';
import 'state.dart';
import 'glass.dart';
import 'role_actions.dart';

class RoleConversationTree extends StatefulWidget {
  const RoleConversationTree({
    super.key,
    required this.store,
    required this.openChat,
    this.query = '',
  });
  final DemoStore store;
  final VoidCallback openChat;
  final String query;
  @override
  State<RoleConversationTree> createState() => _RoleConversationTreeState();
}

class _RoleConversationTreeState extends State<RoleConversationTree> {
  final searchCollapsed = <String>{};
  @override
  void didUpdateWidget(RoleConversationTree oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.query != widget.query) searchCollapsed.clear();
  }

  void create(String id) {
    widget.store.newChat(personaId: id);
    widget.openChat();
  }

  Future<void> menu(Conversation chat, String action) async {
    final store = widget.store;
    if (action == 'pin') {
      store.toggleChatPin(chat.id);
      return;
    }
    if (action == 'delete') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('删除对话？'),
          content: Text('将删除“${chat.title}”及其聊天记录。其他对话和角色卡会保留。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('删除'),
            ),
          ],
        ),
      );
      if (confirmed == true && mounted) store.deleteChat(chat.id);
      return;
    }
    final title = await showDialog<String>(
      context: context,
      builder: (_) => _RenameChatDialog(title: chat.title),
    );
    if (title != null && mounted) store.renameChat(chat.id, title);
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.store,
    builder: (context, _) {
      final store = widget.store, query = widget.query.trim().toLowerCase();
      final folders = [
        for (final role in store.personas)
          if (query.isEmpty ||
              role.name.toLowerCase().contains(query) ||
              store
                  .conversationsFor(role.id)
                  .any((c) => c.title.toLowerCase().contains(query)))
            role,
      ];
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (folders.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 22),
              child: Text(
                '没有找到角色或对话',
                style: TextStyle(fontSize: 12, color: ink),
              ),
            ),
          for (final role in folders) folder(role, query),
        ],
      );
    },
  );

  Widget folder(Persona role, String query) {
    final store = widget.store;
    final all = store.conversationsFor(role.id);
    final roleMatches = role.name.toLowerCase().contains(query);
    final chats = all.where(
      (c) => roleMatches || c.title.toLowerCase().contains(query),
    );
    final expanded = query.isEmpty
        ? store.folderExpanded(role.id)
        : !searchCollapsed.contains(role.id);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            label: '${role.name}，${all.length} 段对话',
            expanded: expanded,
            child: InkWell(
              key: ValueKey('role-folder-${role.id}'),
              borderRadius: BorderRadius.circular(15),
              onTap: () {
                if (query.isEmpty) {
                  store.toggleFolder(role.id);
                } else {
                  setState(() {
                    if (!searchCollapsed.add(role.id))
                      searchCollapsed.remove(role.id);
                  });
                }
              },
              child: Container(
                constraints: const BoxConstraints(minHeight: 48),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: expanded ? .42 : .22),
                  borderRadius: BorderRadius.circular(15),
                ),
                child: Row(
                  children: [
                    Icon(
                      expanded
                          ? Icons.folder_open_outlined
                          : Icons.folder_outlined,
                      size: 20,
                      color: ink,
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        role.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: ink,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${all.length}',
                      key: ValueKey('role-count-${role.id}'),
                      style: const TextStyle(fontSize: 12, color: ink),
                    ),
                    const SizedBox(width: 7),
                    Icon(
                      expanded ? Icons.expand_less : Icons.expand_more,
                      size: 18,
                      color: ink,
                    ),
                    PopupMenuButton<String>(
                      key: ValueKey('role-menu-${role.id}'),
                      tooltip: '角色菜单：${role.name}',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 140),
                      icon: const Icon(Icons.more_horiz, size: 18, color: ink),
                      onSelected: (_) =>
                          confirmDeletePersona(context, store, role),
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'delete', child: Text('删除角色')),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (expanded) ...[
            const SizedBox(height: 4),
            for (final chat in chats) conversation(chat),
            Padding(
              padding: const EdgeInsets.only(left: 12),
              child: TextButton.icon(
                key: ValueKey('role-new-chat-${role.id}'),
                style: TextButton.styleFrom(
                  alignment: Alignment.centerLeft,
                  foregroundColor: ink,
                  minimumSize: const Size(0, 44),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                ),
                onPressed: () => create(role.id),
                icon: const Icon(Icons.add, size: 17),
                label: const Text('新建对话', style: TextStyle(fontSize: 12)),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget conversation(Conversation chat) {
    final store = widget.store;
    final selected = identical(store.conversations[store.conversation], chat);
    return Padding(
      padding: const EdgeInsets.only(left: 12, bottom: 3),
      child: Material(
        key: ValueKey('sidebar-chat-${chat.id}'),
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () {
            store.selectChat(store.conversations.indexOf(chat));
            widget.openChat();
          },
          child: Ink(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              gradient: selected
                  ? LinearGradient(
                      colors: [
                        Colors.white.withValues(alpha: .35),
                        green.withValues(alpha: .10),
                      ],
                    )
                  : null,
              border: selected
                  ? Border.all(color: Colors.white.withValues(alpha: .45))
                  : null,
            ),
            child: Row(
              children: [
                const SizedBox(width: 10),
                Icon(
                  chat.pinned
                      ? Icons.push_pin_outlined
                      : Icons.chat_bubble_outline,
                  size: 14,
                  color: ink,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 11),
                    child: Text(
                      chat.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13, color: ink),
                    ),
                  ),
                ),
                PopupMenuButton<String>(
                  key: ValueKey('chat-menu-${chat.id}'),
                  tooltip: '对话菜单：${chat.title}',
                  icon: const Icon(Icons.more_horiz, size: 19, color: ink),
                  constraints: const BoxConstraints(minWidth: 130),
                  onSelected: (action) => menu(chat, action),
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'rename', child: Text('重命名')),
                    PopupMenuItem(
                      value: 'pin',
                      child: Text(chat.pinned ? '取消置顶' : '置顶'),
                    ),
                    const PopupMenuItem(value: 'delete', child: Text('删除')),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Future<String?> chooseChatRole(BuildContext context, DemoStore store) =>
    showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _RolePicker(store: store),
    );

class _RolePicker extends StatefulWidget {
  const _RolePicker({required this.store});
  final DemoStore store;
  @override
  State<_RolePicker> createState() => _RolePickerState();
}

class _RolePickerState extends State<_RolePicker> {
  String query = '';
  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: GlassSurface(
      radius: 24,
      blur: 18,
      opacity: .82,
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight:
                (MediaQuery.sizeOf(context).height -
                    MediaQuery.viewInsetsOf(context).bottom) *
                .72,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '选择对话角色',
                  style: TextStyle(
                    fontSize: 19,
                    color: ink,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  autofocus: false,
                  decoration: const InputDecoration(
                    hintText: '搜索角色',
                    prefixIcon: Icon(Icons.search),
                  ),
                  onChanged: (v) =>
                      setState(() => query = v.trim().toLowerCase()),
                ),
                const SizedBox(height: 8),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final role in widget.store.personas)
                        if (role.name.toLowerCase().contains(query))
                          ListTile(
                            key: ValueKey('pick-chat-role-${role.id}'),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 4,
                            ),
                            leading: const Icon(
                              Icons.folder_outlined,
                              color: ink,
                            ),
                            title: Text(
                              role.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: ink, fontSize: 14),
                            ),
                            subtitle: Text(
                              '${widget.store.conversationsFor(role.id).length} 段对话',
                              style: const TextStyle(color: ink, fontSize: 11),
                            ),
                            onTap: () => Navigator.pop(context, role.id),
                          ),
                      if (!widget.store.personas.any(
                        (p) => p.name.toLowerCase().contains(query),
                      ))
                        const Padding(
                          padding: EdgeInsets.all(16),
                          child: Text('没有找到角色'),
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

class _RenameChatDialog extends StatefulWidget {
  const _RenameChatDialog({required this.title});
  final String title;
  @override
  State<_RenameChatDialog> createState() => _RenameChatDialogState();
}

class _RenameChatDialogState extends State<_RenameChatDialog> {
  late final input = TextEditingController(text: widget.title);
  final form = GlobalKey<FormState>();
  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  void save() {
    if (form.currentState!.validate()) Navigator.pop(context, input.text);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('重命名对话'),
    content: Form(
      key: form,
      child: TextFormField(
        key: const ValueKey('rename-chat-field'),
        controller: input,
        autofocus: true,
        maxLength: 80,
        decoration: const InputDecoration(labelText: '对话标题'),
        validator: (v) => v?.trim().isEmpty != false ? '请输入对话标题' : null,
        onFieldSubmitted: (_) => save(),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: save, child: const Text('保存')),
    ],
  );
}

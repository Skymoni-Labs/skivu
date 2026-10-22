import 'package:flutter/material.dart';
import 'state.dart';

Future<bool> confirmDeletePersona(
  BuildContext context,
  DemoStore store,
  Persona role,
) async {
  if (store.personas.length <= 1) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('至少保留一个角色，请先创建其他角色。')));
    return false;
  }
  final count = store.conversationsFor(role.id).length;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text('删除角色“${role.name}”？'),
      content: Text(
        count == 0
            ? '将删除这张角色卡。删除后无法恢复。'
            : '将删除角色卡及其 $count 段对话和聊天记录。删除后无法恢复。其他角色和对话会保留。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(c, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(c, true),
          child: Text(count == 0 ? '删除角色' : '删除角色及对话'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return false;
  return store.removePersona(role.id);
}

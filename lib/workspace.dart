import 'package:flutter/material.dart';
import 'widgets.dart';
import 'state.dart';

class WorkspacePanel extends StatelessWidget {
  const WorkspacePanel({super.key, required this.close});
  final VoidCallback close;
  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: Padding(
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              label('工作区', size: 20, weight: FontWeight.w600),
              const Spacer(),
              IconButton(
                tooltip: '关闭工作区',
                onPressed: close,
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          const SizedBox(height: 20),
          for (final item in [
            (Icons.folder_outlined, '文件'),
            (Icons.handyman_outlined, '工具'),
            (Icons.language, '浏览器'),
            (Icons.terminal, '终端'),
          ])
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Pane(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Icon(item.$1, color: ink),
                    const SizedBox(width: 14),
                    Expanded(child: label(item.$2)),
                    Text('即将开放', style: TextStyle(color: ink, fontSize: 12)),
                  ],
                ),
              ),
            ),
          const Spacer(),
          label('更多能力正在准备中。', size: 12),
        ],
      ),
    ),
  );
}

import 'package:flutter/material.dart';
import 'dart:async';
import 'cloud_coding_tools.dart';
import 'cloud_integration.dart';
import 'cloud_storage_page.dart';
import 'cloud_project_browser.dart';
import 'cloud_programs_page.dart';
import 'product_ui.dart';

class CloudCodingPage extends StatefulWidget {
  const CloudCodingPage({super.key});
  @override
  State<CloudCodingPage> createState() => _CloudCodingPageState();
}

class _CloudCodingPageState extends State<CloudCodingPage> {
  Map<String, dynamic> status = {};
  List<dynamic> projects = [];
  String? error;
  bool busy = false;
  int serial = 0;
  @override
  void initState() {
    super.initState();
    refresh();
  }

  Future<dynamic> call(
    String tool,
    Map<String, dynamic> args, {
    String? owner,
    String? scope,
  }) async {
    final r = await cloudExecutionChannel
        .invokeMapMethod<String, dynamic>('invoke', {
          'tool': tool,
          'arguments': args,
          'owner': owner ?? 'cloud:project_browser',
          'taskId': scope ?? 'project_browser',
          'requestId':
              'browser_${DateTime.now().microsecondsSinceEpoch}_${++serial}',
        });
    if (r?['outcome'] != 'verified')
      throw StateError(r?['message'] ?? '操作尚未核对。');
    return r?['value'];
  }

  CloudCall scopedCalls({String? owner}) {
    var scope = 'browser_${DateTime.now().microsecondsSinceEpoch}';
    return (tool, args) async {
      final captured = scope;
      try {
        return await call(tool, args, owner: owner, scope: captured);
      } finally {
        if (tool == 'coding.cancel' && scope == captured)
          scope = 'browser_${DateTime.now().microsecondsSinceEpoch}';
      }
    };
  }

  Future<void> refresh() async {
    setState(() => busy = true);
    try {
      status =
          await cloudExecutionChannel.invokeMapMethod<String, dynamic>(
            'status',
          ) ??
          {};
      // Listing projects requires the runtime. Opening this page only reads its
      // current state; first-time downloads stay behind an explicit action.
      if (status['phase'] == 'ready')
        projects = List.from(await call('coding.projects.list', {}));
      error = null;
    } catch (e) {
      error = '$e';
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> prepare() async {
    setState(() => busy = true);
    final progress = Timer.periodic(const Duration(milliseconds: 500), (
      _,
    ) async {
      try {
        final next = await cloudExecutionChannel
            .invokeMapMethod<String, dynamic>('status');
        if (mounted && busy && next != null) setState(() => status = next);
      } catch (_) {}
    });
    try {
      await call('coding.environment', {});
      projects = List.from(await call('coding.projects.list', {}));
      status =
          await cloudExecutionChannel.invokeMapMethod<String, dynamic>(
            'status',
          ) ??
          {};
      error = null;
    } catch (e) {
      error = '$e';
    } finally {
      progress.cancel();
      if (mounted) setState(() => busy = false);
    }
  }

  String get environmentLabel =>
      const {
        'not_prepared': '尚未准备',
        'verifying': '正在校验',
        'downloading': '正在下载',
        'extracting': '正在准备',
        'starting': '正在启动',
        'ready': '已就绪',
        'interrupted': '需要恢复',
        'unavailable': '暂不可用',
      }[status['phase']] ??
      (busy ? '正在检查' : '尚未检查');

  Future<void> checkMigration() async {
    try {
      var r = await cloudExecutionChannel.invokeMapMethod<String, dynamic>(
        'migration',
      );
      if (r?['state'] == 'bridge_required')
        r = await cloudExecutionChannel.invokeMapMethod<String, dynamic>(
          'migration.activate',
        );
      if (r?['state'] == 'verified') {
        await cloudIntegration.initialize();
        projects = List.from(await call('coding.projects.list', {}));
        status =
            await cloudExecutionChannel.invokeMapMethod<String, dynamic>(
              'status',
            ) ??
            {};
        if (mounted) setState(() => status['migration'] = r);
      }
      if (mounted)
        await showDialog<void>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('迁移核对'),
            content: Text(
              r?['state'] == 'verified'
                  ? '已备份并核对 ${r?['files']} 个文件。旧项目、配置和会话已迁入小云，原组件数据继续保留。${(r?['retainedLinkMetadata'] as num? ?? 0) > 0 ? '\n部分外部链接仅保留原始元数据与备份，请在项目中重新指定对应资源。' : ''}'
                  : r?['message'] ?? '迁移尚未完成，原数据保留。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c),
                child: const Text('关闭'),
              ),
            ],
          ),
        );
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  void environmentDetails() => showMarketDetails(
    context,
    name: '运行环境',
    description: '编程时由小云自动准备和管理。首次准备需要下载资源，之后会复用已有环境。',
    icon: MarketGlyph(
      icon: Icons.code_rounded,
      color: Theme.of(context).colorScheme.primary,
    ),
    details: [
      ('当前状态', environmentLabel),
      if (status['phase'] == 'downloading')
        (
          '下载进度',
          '${((status['downloadedBytes'] as num? ?? 0) / 1048576).toStringAsFixed(1)} / ${((status['downloadBytes'] as num? ?? 0) / 1048576).toStringAsFixed(1)} MB',
        ),
      if (status['migration'] is Map)
        (
          '历史数据',
          const {
                'verified': '已迁移并核对',
                'not_present': '没有旧组件数据',
                'bridge_required': '需要完成迁移连接',
                'not_checked': '尚未检查',
              }[(status['migration'] as Map)['state']] ??
              '待检查',
        ),
    ],
    actions: [
      FilledButton.icon(
        onPressed: busy
            ? null
            : () {
                Navigator.pop(context);
                prepare();
              },
        icon: const Icon(Icons.refresh_rounded, size: 18),
        label: const Text('检查运行环境'),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => ProductScaffold(
    title: '小云项目',
    actions: [
      IconButton(
        onPressed: busy ? null : refresh,
        tooltip: '刷新项目',
        icon: const Icon(Icons.refresh_rounded),
      ),
      PopupMenuButton<String>(
        tooltip: '项目选项',
        onSelected: (value) {
          if (value == 'environment') environmentDetails();
          if (value == 'programs')
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => CloudProgramsPage(
                  callForOwner: (owner) => scopedCalls(owner: owner),
                ),
              ),
            );
          if (value == 'policy')
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const CloudExecutionPolicyPage(),
              ),
            );
          if (value == 'legacy') legacy();
          if (value == 'migration') checkMigration();
          if (value == 'overlay')
            cloudExecutionChannel.invokeMethod('overlay.restore');
        },
        itemBuilder: (_) => [
          const PopupMenuItem(value: 'environment', child: Text('运行环境')),
          const PopupMenuItem(value: 'programs', child: Text('运行记录')),
          const PopupMenuItem(value: 'policy', child: Text('并发与资源设置')),
          PopupMenuItem(
            value: 'legacy',
            enabled: !busy,
            child: const Text('旧项目与会话'),
          ),
          PopupMenuItem(
            value: 'migration',
            enabled: !busy,
            child: const Text('检查历史数据迁移'),
          ),
          const PopupMenuItem(value: 'overlay', child: Text('显示手机操控浮岛')),
        ],
      ),
    ],
    body: ListView(
      padding: const EdgeInsets.all(18),
      children: [
        const Text(
          '把想法交给小云，在这里查看项目、文件和成果。',
          style: TextStyle(fontSize: 14, height: 1.7),
        ),
        const SizedBox(height: 18),
        MarketPanel(
          onTap: environmentDetails,
          child: Row(
            children: [
              Icon(
                status['phase'] == 'ready'
                    ? Icons.check_circle_outline_rounded
                    : Icons.code_rounded,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  '运行环境',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              MarketBadge(environmentLabel),
              const SizedBox(width: 6),
              const Icon(Icons.chevron_right_rounded, size: 20),
            ],
          ),
        ),
        if (busy)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: LinearProgressIndicator(minHeight: 2),
          ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: ProductError(
              message: '项目暂时无法加载',
              detail: error!,
              onRetry: busy ? null : refresh,
            ),
          ),
        const SizedBox(height: 24),
        const Text(
          '我的项目',
          style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 14),
        if (projects.isEmpty &&
            !busy &&
            error == null &&
            status['phase'] == 'ready')
          const ProductEmpty(
            title: '还没有项目',
            description: '在小云对话中提出编程需求，创建的项目会保存在这里。',
          ),
        if (projects.isEmpty &&
            !busy &&
            error == null &&
            status['phase'] != 'ready')
          ProductSection(
            title: '准备后查看项目',
            icon: Icons.code_rounded,
            subtitle: '首次使用需要下载编程环境。已有项目会在环境就绪后显示，原有文件继续保留。',
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  onPressed: prepare,
                  icon: const Icon(Icons.download_outlined, size: 18),
                  label: const Text('准备并查看项目'),
                ),
              ),
            ],
          ),
        for (final project in projects)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: MarketPanel(
              onTap: () => browse(project),
              child: Row(
                children: [
                  MarketGlyph(
                    icon: Icons.folder_outlined,
                    color: Theme.of(context).colorScheme.primary,
                    size: 44,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          project['name'],
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 5),
                        const Text('查看文件与成果', style: TextStyle(fontSize: 12)),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right_rounded),
                ],
              ),
            ),
          ),
        const SizedBox(height: 20),
        ProductSection(
          title: '手机文件',
          icon: Icons.folder_copy_outlined,
          subtitle: '导入已有文件，或选择成果的保存位置。',
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const CloudStoragePage(),
                  ),
                ),
                icon: const Icon(Icons.arrow_forward_rounded, size: 18),
                label: const Text('浏览手机文件'),
              ),
            ),
          ],
        ),
      ],
    ),
  );
  Future<void> browse(dynamic p) async {
    try {
      final value = await call('coding.projects.open', {
        'projectId': p['id'],
      }, owner: p['owner']);
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => CloudProjectBrowser(
            project: Map<String, dynamic>.from(p),
            initial: Map<String, dynamic>.from(value),
            call: scopedCalls(owner: p['owner']),
          ),
        ),
      );
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  Future<void> legacy() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            CloudLegacyBrowser(call: (tool, args) => call(tool, args)),
      ),
    );
  }
}

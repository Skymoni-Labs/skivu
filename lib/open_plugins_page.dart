// SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'open_plugin.dart';
import 'open_plugin_bridge.dart';
import 'open_plugin_page.dart';
import 'cloud_integration.dart';
import 'plugin_market_widgets.dart';

class OpenPluginsPage extends StatefulWidget {
  const OpenPluginsPage({super.key});
  @override
  State<OpenPluginsPage> createState() => _OpenPluginsPageState();
}

class _OpenPluginsPageState extends State<OpenPluginsPage> {
  final catalog = <Map<String, dynamic>>[];
  bool busy = false;
  String? error;
  String query = '';
  bool onlyInstalled = false;
  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      await cloudIntegration.initialize();
      await refresh();
    });
  }

  Future<List<int>> download(String url, int? max) async {
    var uri = Uri.tryParse(url);
    final client = http.Client();
    try {
      final visited = <String>{};
      while (true) {
        if (!visited.add(uri.toString())) throw StateError('下载重定向循环。');
        if (uri == null ||
            uri.scheme != 'https' ||
            uri.host.isEmpty ||
            uri.userInfo.isNotEmpty ||
            uri.hasFragment)
          throw const FormatException('下载地址必须为 HTTPS。');
        final response = await client.send(
          http.Request('GET', uri)..followRedirects = false,
        );
        if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
          final next = response.headers['location'];
          await response.stream.drain<void>();
          if (next == null) throw StateError('redirect');
          uri = uri.resolve(next);
          continue;
        }
        if (response.statusCode != 200) throw StateError('download');
        final bytes = <int>[];
        await for (final part in response.stream) {
          if (max != null && bytes.length + part.length > max)
            throw StateError('size');
          bytes.addAll(part);
        }
        return bytes;
      }
    } finally {
      client.close();
    }
  }

  Future<void> refresh() async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    final found = <String, Map<String, dynamic>>{};
    var failed = 0, skipped = 0;
    for (final url in openPlugins.catalogs) {
      try {
        List<int> bytes;
        try {
          bytes = await download(url, 4 * 1024 * 1024);
        } catch (_) {
          if (url != defaultOpenPluginCatalog &&
              url != legacyOpenPluginCatalog &&
              url != previousOpenPluginCatalog)
            rethrow;
          bytes = await download(
            'https://raw.githubusercontent.com/skyjjgw/skivu-plugins/main/catalog/${Uri.parse(url).pathSegments.last}',
            4 * 1024 * 1024,
          );
        }
        final parsed = parseOpenPluginCatalog(
          jsonDecode(utf8.decode(bytes)),
          url,
        );
        final next = parsed.entries;
        skipped += parsed.skipped;
        // Earlier user-selected catalogs win ID collisions visibly and predictably.
        for (final e in next.entries) found.putIfAbsent(e.key, () => e.value);
      } catch (_) {
        failed++;
      }
    }
    if (mounted)
      setState(() {
        catalog
          ..clear()
          ..addAll(found.values);
        busy = false;
        final notices = [
          if (failed > 0) '$failed 个目录暂时无法读取，已安装插件仍可使用。',
          if (skipped > 0) '$skipped 个条目暂不兼容或格式异常，其他插件仍可安装；可更新 App 后重试。',
        ];
        error = notices.isEmpty ? null : notices.join('\n');
      });
  }

  Future<void> task(Future<void> Function() operation) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await operation();
    } catch (_) {
      if (mounted) setState(() => error = '操作未完成，原有插件与数据已保留。请检查文件、版本和网络后重试。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> showLicense(OpenPluginPackage p) => showDialog<void>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text('${p.manifest.name} · 许可与来源'),
      content: SingleChildScrollView(
        child: SelectableText('${p.notices}\n\n${p.licenseText}'),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('关闭')),
      ],
    ),
  );

  Future<void> previewInstall(OpenPluginPackage p, String origin) async {
    final old = openPlugins.records[p.manifest.id];
    if (!mounted) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('${old == null ? '安装' : '更新'} ${p.manifest.name}？'),
        content: SingleChildScrollView(
          child: SelectableText(
            '${p.manifest.id}\n${p.manifest.author} · ${p.manifest.license}\n${p.manifest.source}\n来源：$origin\n\n${p.manifest.description}\n\n安装后保持关闭，启用前须确认权限。${old != null ? '更新将重置权限授权，自己的存档保留。' : ''}',
          ),
        ),
        actions: [
          TextButton(onPressed: () => showLicense(p), child: const Text('许可')),
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('安装'),
          ),
        ],
      ),
    );
    if (yes == true) await openPlugins.install(p, origin: origin);
  }

  Future<void> localImport() async {
    final f = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(
          label: 'Skivu plugin',
          extensions: ['json'],
          mimeTypes: ['application/json'],
        ),
      ],
    );
    if (f == null) return;
    await previewInstall(
      OpenPluginPackage.parse(await f.readAsString()),
      '本地文件 ${f.name}',
    );
  }

  Future<void> installCatalog(Map<String, dynamic> e) async {
    List<int> bytes;
    if (e['catalog'] == defaultOpenPluginCatalog ||
        e['catalog'] == legacyOpenPluginCatalog ||
        e['catalog'] == previousOpenPluginCatalog) {
      try {
        bytes = await download(
          'https://skymoni.com/app-plugins/web-packages/${e['sha256']}.json',
          maxOpenPluginBytes,
        );
      } catch (_) {
        bytes = await download(e['url'], maxOpenPluginBytes);
      }
    } else {
      bytes = await download(e['url'], maxOpenPluginBytes);
    }
    if (bytes.length != e['bytes'] ||
        sha256.convert(bytes).toString() != e['sha256'])
      throw const FormatException('校验未通过。');
    final p = OpenPluginPackage.parse(utf8.decode(bytes));
    if (!pluginJsonEqual(p.manifest.raw, e['manifest']))
      throw const FormatException('包与目录不一致。');
    await previewInstall(p, e['catalog']);
  }

  Future<void> editCatalogs() async {
    final controller = TextEditingController(
      text: openPlugins.catalogs.join('\n'),
    );
    final value = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('插件目录'),
        content: SizedBox(
          width: 600,
          child: TextField(
            controller: controller,
            maxLines: 8,
            decoration: const InputDecoration(
              labelText: '每行一个 HTTPS JSON 目录',
              helperText: '按从上到下的顺序处理相同插件 ID。',
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value != null) {
      await openPlugins.saveCatalogs(
        value
            .split('\n')
            .map((v) => v.trim())
            .where((v) => v.isNotEmpty)
            .toSet()
            .toList(),
      );
      await refresh();
    }
  }

  Future<void> remove(OpenPluginRecord r) async {
    var erase = false;
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: Text('卸载 ${r.manifest.name}？'),
          content: CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('同时清除本插件存档、工作区与密钥'),
            value: erase,
            onChanged: (v) => set(() => erase = v ?? false),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('卸载'),
            ),
          ],
        ),
      ),
    );
    if (yes != true) return;
    await openPlugins.setEnabled(r.manifest.id, false);
    await openPlugins.uninstall(r.manifest.id);
    if (erase) await eraseOpenPluginData(r.manifest.id);
  }

  Widget glyph(OpenPluginManifest m) => MarketGlyph(
    icon: m.permissions.contains('prompt')
        ? Icons.auto_awesome_rounded
        : m.chatSurface
        ? Icons.forum_rounded
        : Icons.extension_rounded,
    color: m.permissions.contains('prompt')
        ? const Color(0xff8670c7)
        : m.chatSurface
        ? const Color(0xff2589d8)
        : const Color(0xff358b8a),
  );

  void details(OpenPluginManifest m, OpenPluginRecord? record) {
    showMarketDetails(
      context,
      name: m.name,
      description: m.description,
      icon: glyph(m),
      details: [
        ('版本', m.version),
        ('开发者', m.author),
        ('开源许可', m.license),
        ('项目来源', m.source),
        if (record != null) ('安装来源', record.origin),
        ('插件标识', m.id),
        ('适用版本', 'Skivu ${m.raw['minHostVersion']} 及以上'),
        (
          '使用权限',
          m.permissions.isEmpty
              ? '无需额外权限'
              : m.permissions
                    .map((p) => openPluginPermissions[p] ?? p)
                    .join('\n'),
        ),
      ],
      actions: [
        if (record != null)
          TextButton.icon(
            onPressed: () => showLicense(record.package),
            icon: const Icon(Icons.description_outlined, size: 18),
            label: const Text('查看许可原文'),
          ),
      ],
    );
  }

  Future<void> toggle(OpenPluginRecord record) => task(() async {
    if (!record.authorized && !await confirmOpenPlugin(context, record)) return;
    await openPlugins.setEnabled(record.manifest.id, !record.authorized);
  });

  Future<void> selectSurface(OpenPluginRecord record) => task(() async {
    if (!record.authorized) {
      if (!await confirmOpenPlugin(context, record)) return;
      await openPlugins.setEnabled(record.manifest.id, true);
    }
    final id = record.manifest.id;
    await openPlugins.selectChatSurface(
      openPlugins.selectedChatSurface == id ? '' : id,
    );
  });

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: openPlugins,
    builder: (context, _) {
      final available = {
        for (final e in catalog) (e['manifest'] as Map)['id']: e,
      };
      final ids = {...openPlugins.records.keys, ...available.keys}.where((id) {
        if (id == 'org.skivu.dsh' && cloudIntegration.migrated) return false;
        if (onlyInstalled && !openPlugins.records.containsKey(id)) return false;
        final m =
            openPlugins.records[id]?.manifest ??
            OpenPluginManifest.parse(available[id]!['manifest']);
        return '${m.name} ${m.description} ${m.author}'.toLowerCase().contains(
          query.trim().toLowerCase(),
        );
      }).toList();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          MarketHeader(
            title: '工具箱',
            subtitle: '发现提示词、聊天工具和更多玩法。',
            actions: [
              IconButton(
                tooltip: '刷新工具箱',
                onPressed: busy ? null : refresh,
                icon: const Icon(Icons.refresh_rounded, size: 22),
              ),
              PopupMenuButton<String>(
                tooltip: '更多选项',
                icon: const Icon(Icons.more_horiz_rounded),
                enabled: !busy,
                onSelected: (value) {
                  if (value == 'import') task(localImport);
                  if (value == 'catalogs') editCatalogs();
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'import', child: Text('从文件导入')),
                  PopupMenuItem(value: 'catalogs', child: Text('管理插件来源')),
                ],
              ),
            ],
          ),
          const SizedBox(height: 22),
          TextField(
            decoration: marketSearchDecoration(context, '搜索插件'),
            onChanged: (v) => setState(() => query = v),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final installed in [false, true])
                ChoiceChip(
                  label: Text(installed ? '已安装' : '全部'),
                  selected: onlyInstalled == installed,
                  showCheckmark: false,
                  onSelected: (_) => setState(() => onlyInstalled = installed),
                ),
            ],
          ),
          const SizedBox(height: 20),
          if (busy)
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: LinearProgressIndicator(minHeight: 2),
            ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: MarketPanel(
                child: Text(
                  error!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    height: 1.6,
                  ),
                ),
              ),
            ),
          if (ids.isEmpty && !busy)
            MarketPanel(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 20),
                child: Column(
                  children: [
                    Icon(
                      Icons.extension_outlined,
                      size: 36,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(height: 14),
                    Text(
                      query.trim().isNotEmpty
                          ? '没有找到相关插件'
                          : onlyInstalled
                          ? '还没有安装插件'
                          : '暂时没有可用插件',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      query.trim().isNotEmpty
                          ? '试试其他关键词。'
                          : onlyInstalled
                          ? '到“全部”看看有什么新玩法。'
                          : '稍后刷新再来看看。',
                      style: const TextStyle(fontSize: 13),
                    ),
                  ],
                ),
              ),
            ),
          for (final id in ids)
            Builder(
              builder: (context) {
                final r = openPlugins.records[id], e = available[id];
                final m =
                    r?.manifest ?? OpenPluginManifest.parse(e!['manifest']);
                final upgrade =
                    r != null && e != null && e['sha256'] != r.package.digest;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: MarketPanel(
                    onTap: () => details(m, r),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            glyph(m),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    m.name,
                                    style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 5),
                                  if (r != null)
                                    MarketBadge(r.authorized ? '已启用' : '已安装')
                                  else
                                    Text(
                                      m.author,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onSurfaceVariant,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            MarketAction(
                              label: r == null ? '安装' : '打开',
                              onPressed: busy || !m.compatible
                                  ? null
                                  : r == null
                                  ? () => task(() => installCatalog(e!))
                                  : () => launchOpenPlugin(context, r),
                            ),
                            if (r != null)
                              PopupMenuButton<String>(
                                tooltip: '${m.name}管理',
                                padding: EdgeInsets.zero,
                                icon: const Icon(
                                  Icons.more_horiz_rounded,
                                  size: 20,
                                ),
                                onSelected: (value) {
                                  if (value == 'details') details(m, r);
                                  if (value == 'toggle') toggle(r);
                                  if (value == 'surface') selectSurface(r);
                                  if (value == 'update')
                                    task(() => installCatalog(e!));
                                  if (value == 'remove') task(() => remove(r));
                                  if (value == 'license')
                                    showLicense(r.package);
                                },
                                itemBuilder: (_) => [
                                  const PopupMenuItem(
                                    value: 'details',
                                    child: Text('插件详情'),
                                  ),
                                  PopupMenuItem(
                                    value: 'toggle',
                                    enabled: !busy,
                                    child: Text(r.authorized ? '停用插件' : '启用插件'),
                                  ),
                                  if (m.chatSurface)
                                    PopupMenuItem(
                                      value: 'surface',
                                      enabled: !busy,
                                      child: Text(
                                        openPlugins.selectedChatSurface == id
                                            ? '恢复默认聊天界面'
                                            : '设为聊天界面',
                                      ),
                                    ),
                                  if (upgrade)
                                    PopupMenuItem(
                                      value: 'update',
                                      enabled: !busy,
                                      child: const Text('更新插件'),
                                    ),
                                  const PopupMenuItem(
                                    value: 'license',
                                    child: Text('许可与来源'),
                                  ),
                                  PopupMenuItem(
                                    value: 'remove',
                                    enabled: !busy,
                                    child: const Text('卸载插件'),
                                  ),
                                ],
                              ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        Text(
                          m.description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.65,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                        if (upgrade)
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: TextButton.icon(
                                onPressed: busy
                                    ? null
                                    : () => task(() => installCatalog(e)),
                                icon: const Icon(
                                  Icons.upgrade_rounded,
                                  size: 18,
                                ),
                                label: const Text('有新版本'),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
        ],
      );
    },
  );
}

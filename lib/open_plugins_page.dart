// SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'open_plugin.dart';
import 'open_plugin_bridge.dart';
import 'open_plugin_page.dart';

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
  @override
  void initState() {
    super.initState();
    Future.microtask(refresh);
  }

  Future<List<int>> download(String url, int max) async {
    var uri = Uri.tryParse(url);
    final client = http.Client();
    try {
      for (var hop = 0; hop < 4; hop++) {
        if (uri == null ||
            uri.scheme != 'https' ||
            uri.host.isEmpty ||
            uri.userInfo.isNotEmpty ||
            uri.hasFragment)
          throw const FormatException('下载地址必须为 HTTPS。');
        final response = await client
            .send(http.Request('GET', uri)..followRedirects = false)
            .timeout(const Duration(seconds: 30));
        if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
          final next = response.headers['location'];
          await response.stream.drain<void>();
          if (next == null) throw StateError('redirect');
          uri = uri.resolve(next);
          continue;
        }
        if (response.statusCode != 200) throw StateError('download');
        final bytes = <int>[];
        await for (final part in response.stream.timeout(
          const Duration(seconds: 30),
        )) {
          if (bytes.length + part.length > max) throw StateError('size');
          bytes.addAll(part);
        }
        return bytes;
      }
      throw StateError('redirect');
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

  Future<void> previewInstall(OpenPluginPackage p, String origin) async {
    final old = openPlugins.records[p.manifest.id];
    if (!mounted) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('${old == null ? '安装' : '更新'} ${p.manifest.name}？'),
        content: SingleChildScrollView(
          child: SelectableText(
            '${p.manifest.id}\n${p.manifest.author} · ${p.manifest.license}\n${p.manifest.source}\n来源：$origin\n\n${p.manifest.description}\n\n安装后保持关闭，启用前须确认权限。${old != null ? '更新将重置权限授权，自己的存档保留。' : ''}\n\n${p.licenseText}',
          ),
        ),
        actions: [
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
    if (await f.length() > maxOpenPluginBytes)
      throw const FormatException('插件包过大。');
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

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: openPlugins,
    builder: (context, _) {
      final available = {
        for (final e in catalog) (e['manifest'] as Map)['id']: e,
      };
      final ids = {...openPlugins.records.keys, ...available.keys}.where((id) {
        final m =
            openPlugins.records[id]?.manifest ??
            OpenPluginManifest.parse(available[id]!['manifest']);
        return '${m.name} ${m.description} ${m.author}'.toLowerCase().contains(
          query.toLowerCase(),
        );
      }).toList();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            '开放插件',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          const Text('开发者可编写独立页面和聊天动作，自带界面、逻辑与资源。插件从目录或本地安装，启用前由你确认权限。'),
          Wrap(
            spacing: 8,
            children: [
              TextButton.icon(
                onPressed: busy ? null : () => task(localImport),
                icon: const Icon(Icons.file_open_outlined),
                label: const Text('导入插件'),
              ),
              TextButton.icon(
                onPressed: busy ? null : editCatalogs,
                icon: const Icon(Icons.rss_feed),
                label: const Text('管理目录'),
              ),
              TextButton.icon(
                onPressed: busy ? null : refresh,
                icon: const Icon(Icons.refresh),
                label: const Text('刷新'),
              ),
            ],
          ),
          TextField(
            decoration: const InputDecoration(
              labelText: '搜索开放插件',
              prefixIcon: Icon(Icons.search),
            ),
            onChanged: (v) => setState(() => query = v),
          ),
          if (busy) const LinearProgressIndicator(),
          if (error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(error!, style: const TextStyle(color: Colors.red)),
            ),
          Text('${ids.length} 个项目 · ${openPlugins.records.length} 个已安装'),
          if (ids.isEmpty && !busy)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('目录暂无匹配项目。可导入自己编写的 .skivu.json 包，或添加第三方目录。'),
            ),
          for (final id in ids)
            Builder(
              builder: (context) {
                final r = openPlugins.records[id],
                    e = available[id],
                    m = r?.manifest ?? OpenPluginManifest.parse(e!['manifest']);
                return Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          m.name,
                          style: const TextStyle(
                            fontSize: 19,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(m.description),
                        Text('${m.author} · ${m.license} · ${m.version}'),
                        SelectableText(
                          m.source,
                          style: const TextStyle(fontSize: 12),
                        ),
                        if (r != null) Text('安装来源：${r.origin}'),
                        Wrap(
                          spacing: 8,
                          children: [
                            if (r == null && e != null)
                              FilledButton(
                                onPressed: busy
                                    ? null
                                    : () => task(() => installCatalog(e)),
                                child: const Text('安装'),
                              ),
                            if (r != null) ...[
                              if (m.chatSurface)
                                TextButton(
                                  onPressed: busy
                                      ? null
                                      : () => task(() async {
                                          if (!r.authorized) {
                                            if (!await confirmOpenPlugin(
                                              context,
                                              r,
                                            ))
                                              return;
                                            await openPlugins.setEnabled(
                                              id,
                                              true,
                                            );
                                          }
                                          await openPlugins.selectChatSurface(
                                            openPlugins.selectedChatSurface ==
                                                    id
                                                ? ''
                                                : id,
                                          );
                                        }),
                                  child: Text(
                                    openPlugins.selectedChatSurface == id
                                        ? '恢复宿主聊天界面'
                                        : '设为聊天界面',
                                  ),
                                ),
                              FilledButton(
                                onPressed: busy
                                    ? null
                                    : () => launchOpenPlugin(context, r),
                                child: const Text('打开'),
                              ),
                              TextButton(
                                onPressed: busy
                                    ? null
                                    : () => task(() async {
                                        if (!r.authorized &&
                                            !await confirmOpenPlugin(
                                              context,
                                              r,
                                            ))
                                          return;
                                        await openPlugins.setEnabled(
                                          id,
                                          !r.authorized,
                                        );
                                      }),
                                child: Text(r.authorized ? '停用' : '启用'),
                              ),
                              if (e != null && e['sha256'] != r.package.digest)
                                TextButton(
                                  onPressed: busy
                                      ? null
                                      : () => task(() => installCatalog(e)),
                                  child: const Text('更新'),
                                ),
                              TextButton(
                                onPressed: busy
                                    ? null
                                    : () => task(() => remove(r)),
                                child: const Text('卸载'),
                              ),
                              TextButton(
                                onPressed: () => showDialog<void>(
                                  context: context,
                                  builder: (c) => AlertDialog(
                                    title: Text('${m.name} · 许可与来源'),
                                    content: SingleChildScrollView(
                                      child: SelectableText(
                                        '${r.package.notices}\n\n${r.package.licenseText}',
                                      ),
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () => Navigator.pop(c),
                                        child: const Text('关闭'),
                                      ),
                                    ],
                                  ),
                                ),
                                child: const Text('许可'),
                              ),
                            ],
                          ],
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

// SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'extension_market.dart';
import 'mcp_client.dart';
import 'cloud_range_reader.dart';
import 'plugin_market.dart' show comparePluginVersions;
import 'product_ui.dart';
import 'mcp_arguments_editor.dart';

class ExtensionsPage extends StatefulWidget {
  const ExtensionsPage({super.key, this.library, this.autoRefresh = true});
  final ExtensionLibrary? library;
  final bool autoRefresh;
  @override
  State<ExtensionsPage> createState() => _ExtensionsPageState();
}

class _ExtensionsPageState extends State<ExtensionsPage> {
  ExtensionLibrary get library => widget.library ?? extensionLibrary;
  String query = '', filter = 'all';
  int visible = 30;
  @override
  void initState() {
    super.initState();
    if (widget.autoRefresh) Future.microtask(library.refresh);
  }

  Future<void> details(ExtensionInfo info) async {
    final item = library.installed[info.id];
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(info.name),
        content: SizedBox(
          width: 640,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(
                  '${info.author} · ${info.license}\n${info.source['repository']}\n提交 ${info.source['commit']}\n目录 ${info.source['path']}',
                ),
                const SizedBox(height: 16),
                Text(info.description),
                if (item == null)
                  const Padding(
                    padding: EdgeInsets.only(top: 16),
                    child: Text('安装后可查看随包附带的许可原文与来源声明。'),
                  ),
                if (item != null) ...[
                  const SizedBox(height: 16),
                  if (item.payload['requirements'] case final List requirements)
                    Text('使用条件：${requirements.join('；')}'),
                  if (item.kind == 'mcp-http')
                    SelectableText(item.payload['setup']),
                  if (item.kind == 'skill')
                    ExpansionTile(
                      title: const Text('技能指导原文'),
                      children: [SelectableText(item.instruction)],
                    ),
                  if (item.notices.isNotEmpty) SelectableText(item.notices),
                  const SizedBox(height: 16),
                  const Text('许可证原文'),
                  SelectableText(item.licenseText),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> remove(InstalledExtension item) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('卸载${item.name}？'),
        content: const Text('同时关闭该技能或移除工具连接与密钥。聊天记录保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('卸载'),
          ),
        ],
      ),
    );
    if (yes != true) return;
    try {
      if (item.kind == 'mcp-http') await McpConnectionStore().remove(item.id);
      await library.uninstall(item.id);
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('连接密钥未能移除，请重试。')));
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: library,
    builder: (context, _) {
      final all = {
        for (final item in library.installed.values) item.id: item,
        for (final item in library.catalog) item.id: item,
      }.values.toList();
      final matches = all
          .where(
            (item) =>
                (filter == 'all' ||
                    (filter == 'installed'
                        ? library.installed.containsKey(item.id)
                        : item.kind == filter)) &&
                '${item.name} ${item.author} ${item.description}'
                    .toLowerCase()
                    .contains(query.toLowerCase()),
          )
          .toList();
      final busy = library.workingId != null;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          MarketHeader(
            title: '技能与工具',
            subtitle: '为对话添加技能，连接你常用的服务。',
            actions: [
              IconButton(
                tooltip: '刷新技能与工具',
                onPressed: library.loading || busy ? null : library.refresh,
                icon: const Icon(Icons.refresh_rounded, size: 22),
              ),
            ],
          ),
          const SizedBox(height: 22),
          TextField(
            key: const ValueKey('extension-search'),
            decoration: marketSearchDecoration(context, '搜索技能与工具'),
            onChanged: (value) => setState(() {
              query = value;
              visible = 30;
            }),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              for (final option in [
                ('all', '全部'),
                ('skill', '技能'),
                ('mcp-http', 'MCP 工具'),
                ('installed', '已安装'),
              ])
                ChoiceChip(
                  label: Text(option.$2),
                  selected: filter == option.$1,
                  onSelected: (_) => setState(() {
                    filter = option.$1;
                    visible = 30;
                  }),
                ),
            ],
          ),
          if (library.loading) const LinearProgressIndicator(),
          if (library.error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                library.error!,
                style: const TextStyle(color: Colors.red),
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              '${matches.length} 个项目 · ${library.installed.length} 个已安装',
            ),
          ),
          if (matches.isEmpty && !library.loading)
            const Text('暂无匹配项目。可刷新目录，或调整搜索条件。'),
          for (final item in matches.take(visible))
            Builder(
              builder: (context) {
                final installed = library.installed[item.id];
                final upgrade =
                    installed != null &&
                    comparePluginVersions(item.version, installed.version) > 0;
                return Card(
                  margin: const EdgeInsets.only(bottom: 12),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          item.name,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          item.description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13, height: 1.65),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '${item.kind == 'skill' ? '对话技能' : 'MCP 工具'} · ${item.author}',
                          style: const TextStyle(fontSize: 12),
                        ),
                        if (installed != null)
                          Text(
                            '已安装 ${installed.version}',
                            style: const TextStyle(fontSize: 12),
                          ),
                        if (installed?.kind == 'skill')
                          SwitchListTile.adaptive(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('用于对话'),
                            value: library.enabledSkills.contains(item.id),
                            onChanged: busy
                                ? null
                                : (value) =>
                                      library.enableSkill(item.id, value),
                          ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            if (installed == null || upgrade)
                              FilledButton.icon(
                                onPressed:
                                    busy ||
                                        !item.compatible ||
                                        item.packageUrl == null
                                    ? null
                                    : () => library.install(item),
                                icon: library.workingId == item.id
                                    ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(Icons.download_outlined),
                                label: Text(
                                  !item.compatible
                                      ? '需 App ${item.minHostVersion}'
                                      : upgrade
                                      ? '更新'
                                      : '安装',
                                ),
                              ),
                            if (installed?.kind == 'mcp-http')
                              FilledButton.icon(
                                onPressed: busy
                                    ? null
                                    : () => showDialog<void>(
                                        context: context,
                                        builder: (_) => McpToolDialog(
                                          extension: installed!,
                                        ),
                                      ),
                                icon: const Icon(Icons.hub_outlined),
                                label: const Text('连接与使用'),
                              ),
                            TextButton(
                              onPressed: () => details(item),
                              child: const Text('说明与许可'),
                            ),
                            if (installed != null)
                              TextButton(
                                onPressed: busy
                                    ? null
                                    : () => remove(installed),
                                child: const Text('卸载'),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          if (matches.length > visible)
            OutlinedButton(
              onPressed: () => setState(() => visible += 30),
              child: const Text('显示更多'),
            ),
        ],
      );
    },
  );
}

class McpToolDialog extends StatefulWidget {
  const McpToolDialog({super.key, required this.extension});
  final InstalledExtension extension;
  @override
  State<McpToolDialog> createState() => _McpToolDialogState();
}

class _McpToolDialogState extends State<McpToolDialog> {
  final endpoint = TextEditingController(),
      token = TextEditingController(),
      timeout = TextEditingController(text: '0'),
      arguments = TextEditingController(text: '{}');
  final store = McpConnectionStore();
  McpClient? client;
  List<McpTool> tools = [];
  McpTool? selected;
  bool busy = true, remember = false;
  String? error, result;
  Object? resultData;
  bool editingConnection = false;
  bool connected = false;
  GlobalKey<McpArgumentsEditorState> argumentsKey =
      GlobalKey<McpArgumentsEditorState>();
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final saved = await store.load(widget.extension.id);
      if (!mounted) return;
      endpoint.text =
          saved?.endpoint ??
          widget.extension.payload['endpoint'] as String? ??
          '';
      token.text = saved?.token ?? '';
      timeout.text = '${saved?.timeoutSeconds ?? 0}';
      remember = saved != null;
    } catch (_) {
      error = '保存的连接读取失败，请重新填写。';
    }
    if (mounted) setState(() => busy = false);
  }

  void disconnect() {
    client?.close();
    client = null;
    tools = [];
    connected = false;
    selected = null;
    result = null;
    resultData = null;
  }

  Future<void> connect() async {
    setState(() {
      busy = true;
      error = null;
      disconnect();
    });
    McpClient? next;
    try {
      final seconds = int.tryParse(timeout.text.trim());
      if (seconds == null || seconds < 0) {
        throw const FormatException('超时请填写非负整数，0 表示不设置。');
      }
      final config = McpConnection(
        endpoint.text.trim(),
        token: token.text.trim(),
        timeoutSeconds: seconds,
      );
      next = McpClient(config);
      client = next;
      await next.initialize();
      final list = await next.listTools();
      if (!mounted) {
        next.close();
        return;
      }
      if (remember) {
        await store.save(widget.extension.id, config);
      } else {
        await store.remove(widget.extension.id);
      }
      client = next;
      tools = list;
      connected = true;
      editingConnection = false;
    } catch (failure) {
      next?.close();
      client = null;
      error = failure is McpFailure || failure is FormatException
          ? failure.toString()
          : '连接未完成，请检查服务配置。';
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> run() async {
    final tool = selected, connection = client;
    if (tool == null || connection == null) return;
    setState(() {
      busy = true;
      error = null;
      result = null;
    });
    try {
      final params =
          argumentsKey.currentState?.read() ?? jsonDecode(arguments.text);
      if (params is! Map<String, dynamic>)
        throw const FormatException('请填写 JSON 对象，例如 {}。');
      final output = await connection.callTool(tool, params);
      resultData = output;
      result = const JsonEncoder.withIndent('  ').convert(output);
    } catch (failure) {
      error = failure is McpFailure || failure is FormatException
          ? failure.toString()
          : '工具执行未完成。';
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  void dispose() {
    disconnect();
    endpoint.dispose();
    token.dispose();
    timeout.dispose();
    arguments.dispose();
    super.dispose();
  }

  String get resultSummary {
    final value = resultData;
    if (value is Map && value['content'] is List) {
      final text = (value['content'] as List)
          .whereType<Map>()
          .where((c) => c['type'] == 'text')
          .map((c) => c['text'])
          .whereType<String>()
          .join('\n\n');
      if (text.isNotEmpty)
        return text.length > 800 ? '${text.substring(0, 800)}…' : text;
    }
    return '工具已返回内容，可打开完整结果查看。';
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.extension.name),
    backgroundColor: Theme.of(context).colorScheme.surface.withValues(alpha: 1),
    content: SizedBox(
      width: 640,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .68,
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!connected || editingConnection)
                ProductSection(
                  title: '连接服务',
                  icon: Icons.link_rounded,
                  subtitle: '填写服务地址，连接后选择要使用的工具。',
                  children: [
                    TextField(
                      controller: endpoint,
                      enabled: !busy,
                      keyboardType: TextInputType.url,
                      decoration: const InputDecoration(
                        labelText: '服务地址',
                        hintText: 'https://…',
                      ),
                      onChanged: (_) => setState(disconnect),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: token,
                      enabled: !busy,
                      obscureText: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: const InputDecoration(labelText: '访问密钥（可选）'),
                      onChanged: (_) => setState(disconnect),
                    ),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text(
                        '记住此连接',
                        style: TextStyle(fontSize: 13),
                      ),
                      subtitle: const Text(
                        '密钥单独保存在设备安全存储中。',
                        style: TextStyle(fontSize: 11),
                      ),
                      value: remember,
                      onChanged: busy
                          ? null
                          : (v) => setState(() => remember = v!),
                    ),
                    ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      title: const Text('连接选项', style: TextStyle(fontSize: 13)),
                      children: [
                        TextField(
                          controller: timeout,
                          enabled: !busy,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: '请求超时（秒）',
                            helperText: '0 不设置；关闭窗口可取消等待。',
                          ),
                          onChanged: (_) => setState(disconnect),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          widget.extension.payload['setup'],
                          style: const TextStyle(fontSize: 12, height: 1.6),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: busy ? null : connect,
                      icon: const Icon(Icons.link_rounded, size: 18),
                      label: const Text('连接服务'),
                    ),
                  ],
                )
              else
                ProductSection(
                  title: '服务已连接',
                  icon: Icons.check_circle_outline_rounded,
                  children: [
                    Text(
                      '${tools.length} 个可用工具',
                      style: const TextStyle(fontSize: 13),
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: busy
                            ? null
                            : () => setState(() => editingConnection = true),
                        child: const Text('修改连接'),
                      ),
                    ),
                  ],
                ),
              if (busy)
                const Padding(
                  padding: EdgeInsets.only(bottom: 16),
                  child: LinearProgressIndicator(minHeight: 2),
                ),
              if (client != null && !busy && tools.isEmpty)
                const ProductEmpty(
                  title: '服务暂未提供工具',
                  description: '可以稍后重新连接，或检查服务端设置。',
                  icon: Icons.extension_outlined,
                ),
              if (tools.isNotEmpty && !editingConnection)
                ProductSection(
                  title: '选择并使用工具',
                  icon: Icons.handyman_outlined,
                  children: [
                    DropdownButtonFormField<String>(
                      initialValue: selected?.name,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: '选择工具'),
                      items: [
                        for (final tool in tools)
                          DropdownMenuItem(
                            value: tool.name,
                            child: Text(
                              tool.name,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: busy
                          ? null
                          : (name) => setState(() {
                              selected = tools.firstWhere(
                                (tool) => tool.name == name,
                              );
                              result = null;
                              resultData = null;
                              arguments.text = '{}';
                              argumentsKey =
                                  GlobalKey<McpArgumentsEditorState>();
                            }),
                    ),
                    if (selected != null) ...[
                      const SizedBox(height: 14),
                      Text(
                        selected!.description,
                        style: const TextStyle(fontSize: 13, height: 1.6),
                      ),
                      const SizedBox(height: 14),
                      McpArgumentsEditor(
                        key: argumentsKey,
                        schema: selected!.inputSchema,
                        controller: arguments,
                        enabled: !busy,
                      ),
                      const SizedBox(height: 14),
                      const Text(
                        '执行时会把填写的参数发送到已连接的服务。',
                        style: TextStyle(fontSize: 12, height: 1.6),
                      ),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: busy ? null : run,
                        icon: const Icon(Icons.play_arrow_rounded, size: 18),
                        label: const Text('执行工具'),
                      ),
                    ],
                  ],
                ),
              if (error != null)
                ProductError(message: '操作未完成，请检查连接或参数', detail: error!),
              if (result != null)
                ProductSection(
                  title: '工具返回的结果',
                  icon: Icons.task_alt_rounded,
                  children: [
                    SelectableText(
                      resultSummary,
                      style: const TextStyle(fontSize: 13, height: 1.65),
                    ),
                    ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      title: const Text(
                        '查看原始数据',
                        style: TextStyle(fontSize: 12),
                      ),
                      children: [
                        SelectableText(
                          result!.length > 4000
                              ? '${result!.substring(0, 4000)}\n此处为预览，可打开完整结果。'
                              : result!,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        TextButton.icon(
                          onPressed: () {
                            final bytes = utf8.encode(result!);
                            Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => CloudRangeReader(
                                  title: '完整执行结果',
                                  read: (offset) async {
                                    var end = (offset + 48000).clamp(
                                      0,
                                      bytes.length,
                                    );
                                    while (end < bytes.length &&
                                        (bytes[end] & 0xc0) == 0x80) {
                                      end--;
                                    }
                                    return {
                                      'text': utf8.decode(
                                        bytes.sublist(offset, end),
                                      ),
                                      'nextOffset': end,
                                      'bytes': bytes.length,
                                      'complete': end == bytes.length,
                                    };
                                  },
                                ),
                              ),
                            );
                          },
                          icon: const Icon(Icons.article_outlined),
                          label: const Text('查看完整结果'),
                        ),
                        TextButton.icon(
                          onPressed: () =>
                              Clipboard.setData(ClipboardData(text: result!)),
                          icon: const Icon(Icons.copy),
                          label: const Text('复制结果'),
                        ),
                      ],
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
    ],
  );
}

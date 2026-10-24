// SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'extension_market.dart';
import 'mcp_client.dart';
import 'plugin_market.dart' show comparePluginVersions;

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
          Row(
            children: [
              const Expanded(
                child: Text(
                  '技能与工具',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
                ),
              ),
              IconButton(
                tooltip: '刷新技能与工具',
                onPressed: library.loading || busy ? null : library.refresh,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          const Text(
            '技能开启后会用于新的对话请求。MCP 工具需配置服务地址，并由你选择工具执行。',
            style: TextStyle(height: 1.7),
          ),
          const SizedBox(height: 16),
          TextField(
            key: const ValueKey('extension-search'),
            decoration: const InputDecoration(
              labelText: '搜索名称、作者或用途',
              prefixIcon: Icon(Icons.search),
              border: OutlineInputBorder(),
            ),
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
                        Text(item.description),
                        const SizedBox(height: 8),
                        Text(
                          '${item.kind == 'skill' ? '技能指导' : 'MCP 工具'} · ${item.author} · ${item.license}',
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
      arguments = TextEditingController(text: '{}');
  final store = McpConnectionStore();
  McpClient? client;
  List<McpTool> tools = [];
  McpTool? selected;
  bool busy = true, remember = false;
  String? error, result;
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
    selected = null;
    result = null;
  }

  Future<void> connect() async {
    setState(() {
      busy = true;
      error = null;
      disconnect();
    });
    McpClient? next;
    try {
      final config = McpConnection(
        endpoint.text.trim(),
        token: token.text.trim(),
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
      final params = jsonDecode(arguments.text);
      if (params is! Map<String, dynamic>)
        throw const FormatException('请填写 JSON 对象，例如 {}。');
      final output = await connection.callTool(tool, params);
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
    arguments.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.extension.name),
    content: SizedBox(
      width: 640,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.extension.payload['setup']),
            const SizedBox(height: 12),
            TextField(
              controller: endpoint,
              enabled: !busy,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(labelText: 'HTTPS MCP 地址'),
              onChanged: (_) => setState(disconnect),
            ),
            TextField(
              controller: token,
              enabled: !busy,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(labelText: 'Bearer 访问密钥（如需要）'),
              onChanged: (_) => setState(disconnect),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('在本机记住连接'),
              subtitle: const Text('密钥保存在设备安全存储中。'),
              value: remember,
              onChanged: busy ? null : (v) => setState(() => remember = v!),
            ),
            FilledButton(
              onPressed: busy ? null : connect,
              child: const Text('连接并获取工具'),
            ),
            if (busy)
              const Padding(
                padding: EdgeInsets.all(12),
                child: LinearProgressIndicator(),
              ),
            if (client != null && !busy && tools.isEmpty)
              const Text('服务目前没有可用工具。'),
            if (tools.isNotEmpty) ...[
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: selected?.name,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '选择工具'),
                items: [
                  for (final tool in tools)
                    DropdownMenuItem(
                      value: tool.name,
                      child: Text(tool.name, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: busy
                    ? null
                    : (name) => setState(() {
                        selected = tools.firstWhere(
                          (tool) => tool.name == name,
                        );
                        result = null;
                      }),
              ),
              if (selected != null) ...[
                const SizedBox(height: 12),
                Text(selected!.description),
                ExpansionTile(
                  title: const Text('参数格式'),
                  children: [
                    SelectableText(
                      const JsonEncoder.withIndent(
                        '  ',
                      ).convert(selected!.inputSchema),
                    ),
                  ],
                ),
                TextField(
                  controller: arguments,
                  enabled: !busy,
                  minLines: 3,
                  maxLines: 10,
                  decoration: const InputDecoration(
                    labelText: '工具参数（JSON 对象）',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  '点击执行会将这些参数发送给上面配置的服务。请检查工具用途和参数。',
                  style: TextStyle(fontSize: 12),
                ),
                FilledButton(
                  onPressed: busy ? null : run,
                  child: const Text('执行所选工具'),
                ),
              ],
            ],
            if (error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(error!, style: const TextStyle(color: Colors.red)),
              ),
            if (result != null) ...[
              const SizedBox(height: 12),
              const Text('执行结果'),
              SelectableText(
                result!.length > 40000
                    ? '${result!.substring(0, 40000)}\n\n结果较长，此处显示前 40,000 个字符，可复制完整结果。'
                    : result!,
              ),
              TextButton.icon(
                onPressed: () =>
                    Clipboard.setData(ClipboardData(text: result!)),
                icon: const Icon(Icons.copy),
                label: const Text('复制结果'),
              ),
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
  );
}

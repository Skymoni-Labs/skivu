// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'open_plugin.dart';
import 'open_plugin_bridge.dart';
import 'open_plugin_network.dart';
import 'open_plugin_external.dart';
import 'state.dart';
import 'chat_api.dart';

Future<bool> confirmOpenPlugin(
  BuildContext context,
  OpenPluginRecord r,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('启用 ${r.manifest.name}？'),
        content: SizedBox(
          width: 540,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(
                  '${r.manifest.author}\n${r.manifest.source}\n版本 ${r.manifest.version}\n包校验 ${r.package.digest}',
                ),
                const SizedBox(height: 16),
                const Text('此插件将运行自己的界面与代码，并可请求以下能力：'),
                for (final p in r.manifest.permissions)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text('• ${openPluginPermissions[p]}'),
                  ),
                if (r.manifest.domains.isNotEmpty)
                  Text('网络域名：${r.manifest.domains.join('、')}'),
                const SizedBox(height: 12),
                const Text('插件只能使用自己保存的第三方密钥；宿主账号、服务器配置和模型密钥不会提供给插件。'),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('同意并启用'),
          ),
        ],
      ),
    ) ??
    false;

Future<void> launchOpenPlugin(
  BuildContext context,
  OpenPluginRecord record, {
  String? action,
  OpenPluginRegistry? registry,
}) async {
  final library = registry ?? openPlugins;
  if (!record.authorized) {
    if (!record.manifest.compatible) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先更新 App。')));
      return;
    }
    if (!await confirmOpenPlugin(context, record)) return;
    if (library.records[record.manifest.id] != record) return;
    await library.setEnabled(record.manifest.id, true);
  }
  if (context.mounted)
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            OpenPluginPage(record: record, registry: library, action: action),
      ),
    );
}

class OpenPluginPage extends StatefulWidget {
  const OpenPluginPage({
    super.key,
    required this.record,
    required this.registry,
    this.action,
    this.embedded = false,
  });
  final OpenPluginRecord record;
  final OpenPluginRegistry registry;
  final String? action;
  final bool embedded;
  @override
  State<OpenPluginPage> createState() => _OpenPluginPageState();
}

class _OpenPluginPageState extends State<OpenPluginPage>
    with WidgetsBindingObserver {
  late OpenPluginBridge bridge;
  MethodChannel? channel;
  String? roleId, chatId;
  String contextSnapshot = '';
  final logs = <String>[];
  final sessions = <ChatSession>{};
  bool confirming = false, generating = false;
  int generation = 0;
  @override
  void initState() {
    super.initState();
    roleId = demo.role.id;
    chatId = demo.conversations[demo.conversation].id;
    bridge = OpenPluginBridge(
      registry: widget.registry,
      record: widget.record,
      host: hostCall,
    );
    demo.addListener(contextChanged);
    widget.registry.addListener(registryChanged);
    WidgetsBinding.instance.addObserver(this);
  }

  Map<String, dynamic> get hostContext {
    final role = demo.personas.where((r) => r.id == roleId).firstOrNull;
    final chat = demo.conversations
        .where((c) => c.id == chatId && c.personaId == roleId)
        .firstOrNull;
    return {
      'roleId': role?.id,
      'roleName': role?.name,
      'chatId': chat?.id,
      'action': widget.action,
    };
  }

  void contextChanged() {
    if (!mounted) return;
    if (widget.embedded) {
      roleId = demo.role.id;
      chatId = demo.conversations[demo.conversation].id;
    }
    if (!demo.personas.any((r) => r.id == roleId))
      roleId = demo.personas.firstOrNull?.id;
    if (!demo.conversations.any((c) => c.id == chatId && c.personaId == roleId))
      chatId = demo.conversations
          .where((c) => c.personaId == roleId)
          .firstOrNull
          ?.id;
    final encoded = jsonEncode(hostContext);
    if (encoded != contextSnapshot) {
      contextSnapshot = encoded;
      unawaited(
        channel?.invokeMethod('event', {
          'name': 'context.changed',
          'detail': hostContext,
        }),
      );
      setState(() {});
    }
  }

  void registryChanged() {
    if (!widget.record.authorized ||
        widget.registry.records[widget.record.manifest.id] != widget.record) {
      bridge.close();
      for (final s in sessions) s.cancel();
      if (mounted) setState(() {});
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      for (final s in sessions) s.cancel();
      unawaited(
        channel?.invokeMethod('event', {'name': 'host.pause', 'detail': null}),
      );
    }
  }

  @override
  void dispose() {
    unawaited(
      channel?.invokeMethod('event', {'name': 'host.suspend', 'detail': null}),
    );
    channel?.setMethodCallHandler(null);
    bridge.close();
    for (final s in sessions) s.cancel();
    demo.removeListener(contextChanged);
    widget.registry.removeListener(registryChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<bool> confirm(String title, String detail) async {
    bridge.check();
    if (confirming) throw const PluginApiError('BUSY', '已有操作等待确认。');
    confirming = true;
    try {
      return await showDialog<bool>(
            context: context,
            builder: (c) => AlertDialog(
              title: Text(title),
              content: SingleChildScrollView(
                child: Text('${widget.record.manifest.name} 请求：\n\n$detail'),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(c, false),
                  child: const Text('拒绝'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(c, true),
                  child: const Text('允许本次'),
                ),
              ],
            ),
          ) ??
          false;
    } finally {
      confirming = false;
    }
  }

  Future<void> allow(String title, String detail) async {
    if (!await confirm(title, detail))
      throw const PluginApiError('USER_DENIED', '用户取消了这次操作。');
    bridge.check();
  }

  Future<Object?> hostCall(String method, Map<String, dynamic> p) async {
    bridge.check();
    if (method == 'context.get') return hostContext;
    if (method == 'ui.openExternal') {
      return openPluginExternal(
        p,
        check: bridge.check,
        confirm: (uri) => confirm(
          '打开外部软件或网页？',
          '${widget.record.manifest.name} 请求打开：\n$uri\n\n由系统浏览器或关联软件处理。打开不表示已登录、发送、购买或完成其他业务；外部软件自行管理其账号。',
        ),
      );
    }
    if (method == 'ui.toast') {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(bridge.text(p, 'text', max: 300))));
      return true;
    }
    if (method == 'clipboard.read')
      return (await Clipboard.getData('text/plain'))?.text;
    if (method == 'clipboard.write') {
      await Clipboard.setData(
        ClipboardData(
          text: bridge.text(p, 'text', max: 1024 * 1024, empty: true),
        ),
      );
      return true;
    }
    if (method == 'files.pick') {
      final value = await const MethodChannel(
        'skivu/open_plugin_files',
      ).invokeMapMethod<String, dynamic>('pick');
      if (value == null) return null;
      return {
        'name': value['name'],
        'mime': value['mime'],
        'base64': base64Encode(value['bytes'] as Uint8List),
      };
    }
    if (method == 'files.save') {
      final bytes = base64Decode(
        bridge.text(p, 'base64', max: 12 * 1024 * 1024, empty: true),
      );
      if (bytes.length > 8 * 1024 * 1024)
        throw const PluginApiError('LIMIT_EXCEEDED', '文件超过 8 MiB。');
      return await const MethodChannel(
            'skivu/open_plugin_files',
          ).invokeMethod<bool>('save', {
            'name': bridge.text(p, 'name', max: 160),
            'mime': bridge.text(p, 'mime', max: 150),
            'bytes': Uint8List.fromList(bytes),
          }) ??
          false;
    }
    Map<String, dynamic> character(Persona r) => {
      'id': r.id,
      'name': r.name,
      'subtitle': r.subtitle,
      'prompt': r.prompt,
      'card': Map<String, String>.from(r.card),
    };
    if (method == 'characters.list')
      return demo.personas.map(character).toList();
    if (method == 'characters.get' || method == 'characters.update') {
      final r = demo.personas.where((r) => r.id == p['roleId']).firstOrNull;
      if (r == null) throw const PluginApiError('NOT_FOUND', '角色已不存在。');
      if (method == 'characters.get') return character(r);
      const allowed = {'roleId', 'name', 'subtitle', 'prompt', 'card'};
      if (p.keys.any((k) => !allowed.contains(k)))
        throw const PluginApiError('INVALID_ARGUMENT', '角色字段不受支持。');
      final old = character(r);
      final name = p.containsKey('name')
          ? bridge.text(p, 'name', max: 100)
          : r.name;
      final subtitle = p.containsKey('subtitle')
          ? bridge.text(p, 'subtitle', max: 1000, empty: true)
          : r.subtitle;
      final prompt = p.containsKey('prompt')
          ? bridge.text(p, 'prompt', max: 60000, empty: true)
          : r.prompt;
      final card = p['card'] ?? r.card;
      if (card is! Map ||
          card.length > 100 ||
          card.entries.any(
            (e) =>
                e.key is! String ||
                e.value is! String ||
                (e.key as String).length > 100 ||
                (e.value as String).length > 6000,
          ))
        throw const PluginApiError('INVALID_ARGUMENT', '角色卡格式不正确。');
      await allow(
        '修改角色资料？',
        '角色：${r.name}\n新名称：$name\n设定：${prompt.substring(0, prompt.length.clamp(0, 1000))}\n角色卡字段：${card.keys.join('、')}',
      );
      if (!demo.personas.contains(r))
        throw const PluginApiError('NOT_FOUND', '角色已不存在。');
      r.name = name;
      r.subtitle = subtitle;
      r.prompt = prompt;
      r.card = Map<String, String>.from(card);
      try {
        await demo.saveChats();
        if (demo.storageError != null) throw StateError('save');
      } catch (_) {
        r.name = old['name'];
        r.subtitle = old['subtitle'];
        r.prompt = old['prompt'];
        r.card = Map<String, String>.from(old['card']);
        rethrow;
      }
      demo.changed();
      return true;
    }
    if (method == 'chat.read' || method == 'chat.append') {
      final chat = demo.conversations
          .where((c) => c.id == chatId && c.personaId == roleId)
          .firstOrNull;
      if (chat == null) throw const PluginApiError('NOT_FOUND', '请先在宿主选择已有聊天。');
      if (method == 'chat.read') {
        final count = p['limit'] ?? 50;
        if (count is! int || count < 1 || count > 100)
          throw const PluginApiError('INVALID_ARGUMENT', '消息数须为 1 到 100。');
        final list = chat.messages
            .where((m) => m.text.isNotEmpty && m.status != 'pending')
            .toList();
        return [
          for (final m in list.skip(
            (list.length - count).clamp(0, list.length),
          ))
            {
              'id': '${chat.id}:${chat.messages.indexOf(m)}',
              'role': m.user ? 'user' : 'assistant',
              'text': m.text,
            },
        ];
      }
      final text = bridge.text(p, 'text', max: 60000), role = p['role'];
      if (!['user', 'assistant'].contains(role))
        throw const PluginApiError('INVALID_ARGUMENT', '消息身份不正确。');
      await allow(
        '写入聊天？',
        '所选角色：${hostContext['roleName']}\n身份：$role\n${text.substring(0, text.length.clamp(0, 2000))}',
      );
      if (!demo.conversations.contains(chat))
        throw const PluginApiError('NOT_FOUND', '聊天已不存在。');
      final message = Message(role == 'user', text);
      chat.messages.add(message);
      try {
        await demo.saveChats();
        if (demo.storageError != null) throw StateError('save');
      } catch (_) {
        chat.messages.remove(message);
        rethrow;
      }
      demo.changed();
      return {'id': '${chat.id}:${chat.messages.indexOf(message)}'};
    }
    if (method == 'prompt.set') {
      final role = roleId;
      if (role == null) throw const PluginApiError('NOT_FOUND', '请先选择角色。');
      await widget.registry.setPrompt(
        widget.record.manifest.id,
        role,
        bridge.text(p, 'text', max: 32768, empty: true),
      );
      return true;
    }
    if (method == 'ai.generate') return generate(p);
    throw const PluginApiError('METHOD_NOT_FOUND', '该宿主能力尚未开放。');
  }

  Future<Object?> generate(Map<String, dynamic> p) async {
    if (generating) throw const PluginApiError('BUSY', '本插件已有生成任务。');
    final instruction = bridge.text(p, 'instruction', max: 60000),
        role = p['roleId'] ?? roleId;
    if (role is! String || !demo.personas.any((r) => r.id == role))
      throw const PluginApiError('NOT_FOUND', '角色已不存在。');
    final max = p['maxOutput'] ?? 1024, context = p['context'] ?? [];
    if (max is! int ||
        max < 16 ||
        max > 4096 ||
        context is! List ||
        context.length > 50 ||
        utf8.encode(jsonEncode(context)).length > 65536)
      throw const PluginApiError('INVALID_ARGUMENT', '生成参数超出范围。');
    final history = <Map<String, String>>[];
    for (final m in context) {
      if (m is! Map ||
          m.length != 2 ||
          !['user', 'assistant'].contains(m['role']) ||
          m['content'] is! String)
        throw const PluginApiError('INVALID_ARGUMENT', '上下文格式不正确。');
      history.add(Map<String, String>.from(m));
    }
    await allow(
      '使用当前模型生成？',
      '角色：${demo.personas.firstWhere((r) => r.id == role).name}\n最多输出 $max token；会按当前模型设置消耗额度。\n\n${instruction.substring(0, instruction.length.clamp(0, 2000))}\n\n插件提供 ${history.length} 条上下文。',
    );
    generating = true;
    ChatSession? session;
    try {
      session = await demo.startPluginReply(role, instruction, history, max);
      bridge.check();
      sessions.add(session);
      var text = '', usage = const ApiUsage();
      await for (final event in session.events.timeout(
        const Duration(seconds: 90),
      )) {
        bridge.check();
        text += event.text;
        if (text.length > 256 * 1024)
          throw const PluginApiError('LIMIT_EXCEEDED', '生成结果过长。');
        if (event.usage != null) usage = usage.merge(event.usage!);
      }
      return {
        'text': text,
        'usage': {
          'input': usage.input,
          'output': usage.output,
          'cached': usage.cached,
        },
      };
    } on ChatFailure catch (e) {
      if (e.code == 'model_not_available')
        throw const PluginApiError(
          'model_not_available',
          '模型未开放或已下架，请更新模型列表并切换到当前可用模型',
        );
      throw const PluginApiError('MODEL_FAILED', '模型请求未完成，请在宿主检查模型选择、登录或额度。');
    } finally {
      if (session != null) {
        session.cancel();
        sessions.remove(session);
      }
      generating = false;
    }
  }

  void created(int viewId) {
    final epoch = generation;
    channel = MethodChannel('skivu/open_plugin/$viewId');
    channel!.setMethodCallHandler((call) async {
      if (call.method == 'request') {
        if (epoch != generation)
          return {
            'ok': false,
            'error': {'code': 'CLOSED', 'message': '页面已重新加载。'},
          };
        try {
          return await bridge.dispatch(jsonDecode(call.arguments as String));
        } catch (_) {
          return {
            'ok': false,
            'error': {'code': 'INVALID_ARGUMENT', 'message': '请求格式不正确。'},
          };
        }
      }
      if (call.method == 'console' && mounted) {
        final raw = call.arguments as Map;
        logs.add('${raw['level']} L${raw['line']}: ${raw['message']}');
        if (logs.length > 100) logs.removeAt(0);
      }
      return null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final supported =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    return Scaffold(
      appBar: widget.embedded
          ? null
          : AppBar(
              title: Text(widget.record.manifest.name),
              actions: [
                IconButton(
                  tooltip: '插件日志',
                  icon: const Icon(Icons.terminal),
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (c) => AlertDialog(
                      title: const Text('本插件日志'),
                      content: SizedBox(
                        width: 600,
                        child: SingleChildScrollView(
                          child: SelectableText(
                            logs.isEmpty ? '暂无日志' : logs.join('\n'),
                          ),
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
                ),
                IconButton(
                  tooltip: '重新加载插件',
                  icon: const Icon(Icons.refresh),
                  onPressed: () {
                    bridge.check();
                    if (bridge.pending > 0) return;
                    bridge.close();
                    bridge = OpenPluginBridge(
                      registry: widget.registry,
                      record: widget.record,
                      host: hostCall,
                    );
                    setState(() {
                      generation++;
                    });
                  },
                ),
              ],
            ),
      body: Padding(
        padding: EdgeInsets.only(
          top: widget.embedded
              ? appToolbarHeight + 8 + MediaQuery.paddingOf(context).top
              : 0,
        ),
        child: SafeArea(
          child: Column(
            children: [
              if (!widget.embedded)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      const Text('上下文角色：'),
                      Expanded(
                        child: DropdownButton<String>(
                          isExpanded: true,
                          value: roleId,
                          items: [
                            for (final r in demo.personas)
                              DropdownMenuItem(
                                value: r.id,
                                child: Text(
                                  r.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: (v) {
                            roleId = v;
                            chatId = null;
                            contextChanged();
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              if (bridge.closed)
                const Expanded(
                  child: Center(child: Text('插件已关闭或更新，请返回插件市场重新启用。')),
                )
              else if (!supported)
                const Expanded(
                  child: Center(child: Text('请在 Android App 中运行此插件。')),
                )
              else
                Expanded(
                  child: AndroidView(
                    key: ValueKey(generation),
                    viewType: 'skivu/open-plugin',
                    creationParams: {
                      'entry': widget.record.manifest.entry,
                      'digest': widget.record.package.digest,
                      'files': widget.record.package.files,
                    },
                    creationParamsCodec: const StandardMessageCodec(),
                    onPlatformViewCreated: created,
                    gestureRecognizers: {
                      Factory<OneSequenceGestureRecognizer>(
                        () => EagerGestureRecognizer(),
                      ),
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class OpenPluginChatButton extends StatelessWidget {
  const OpenPluginChatButton({super.key});
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: openPlugins,
    builder: (context, _) =>
        openPlugins.records.values.any(
          (r) => r.authorized && r.manifest.chatActions.isNotEmpty,
        )
        ? IconButton(
            tooltip: '插件动作',
            onPressed: () => showOpenPluginActions(context),
            icon: const Icon(Icons.extension_outlined),
          )
        : const SizedBox.shrink(),
  );
}

Future<void> showOpenPluginActions(BuildContext context) async {
  final entries = [
    for (final r in openPlugins.records.values)
      if (r.authorized)
        for (final a in r.manifest.chatActions) (r, a),
  ];
  if (entries.isEmpty) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('可在插件市场安装并启用带聊天动作的插件。')));
    return;
  }
  final choice = await showModalBottomSheet<int>(
    context: context,
    builder: (c) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          const ListTile(title: Text('插件动作')),
          for (var i = 0; i < entries.length; i++)
            ListTile(
              title: Text(entries[i].$2['title']),
              subtitle: Text(entries[i].$1.manifest.name),
              onTap: () => Navigator.pop(c, i),
            ),
        ],
      ),
    ),
  );
  if (choice != null && context.mounted)
    await launchOpenPlugin(
      context,
      entries[choice].$1,
      action: entries[choice].$2['id'],
    );
}

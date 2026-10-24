import 'dart:async';
import 'package:flutter/material.dart';
import 'chat_api.dart';
import 'model_connection.dart';
import 'model_settings.dart';
import 'state.dart';
import 'widgets.dart';

class ModelSettingsPage extends StatelessWidget {
  const ModelSettingsPage({super.key});

  Future<void> edit(BuildContext context, [ModelConnection? profile]) =>
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        constraints: const BoxConstraints(maxWidth: 560),
        builder: (_) => _ConnectionEditor(profile: profile),
      );

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: modelSettings,
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (modelSettings.error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text(modelSettings.error!),
          ),
        if (modelSettings.connections.isEmpty)
          Pane(
            child: Column(
              children: [
                Icon(Icons.hub_outlined, size: 40, color: green),
                const SizedBox(height: 16),
                label('连接你喜欢的模型', size: 19, weight: FontWeight.w600),
                const SizedBox(height: 8),
                label('选择服务商，填写 API 地址、密钥与模型，即可开始对话。', size: 12, color: muted),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: () => edit(context),
                  icon: const Icon(Icons.add),
                  label: const Text('添加模型连接'),
                ),
              ],
            ),
          )
        else ...[
          for (final profile in modelSettings.connections) ...[
            Pane(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: green.withValues(alpha: .1),
                          borderRadius: BorderRadius.circular(13),
                        ),
                        child: Icon(Icons.hub_outlined, color: green, size: 22),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            label(profile.name, weight: FontWeight.w600),
                            label(profile.provider, size: 11, color: muted),
                          ],
                        ),
                      ),
                      if (modelSettings.activeId == profile.id)
                        const TinyTag('当前使用'),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Text(profile.model, style: const TextStyle(fontSize: 13)),
                  const SizedBox(height: 4),
                  Text(
                    '${profile.protocol.label} · ${Uri.tryParse(profile.address)?.host ?? ''}',
                    style: TextStyle(fontSize: 11, color: muted),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      TextButton.icon(
                        onPressed: demo.streaming
                            ? null
                            : () async {
                                try {
                                  await modelSettings.select(profile.id);
                                  demo.useBeta = false;
                                  demo.useAccount = false;
                                  demo.changed();
                                  demo.saveChats();
                                } catch (_) {
                                  if (context.mounted)
                                    toast(context, '无法保存选择，请重试');
                                }
                              },
                        icon: Icon(
                          modelSettings.activeId == profile.id
                              ? Icons.check_circle_outline
                              : Icons.radio_button_unchecked,
                          size: 17,
                        ),
                        label: Text(
                          modelSettings.activeId == profile.id
                              ? '已选择'
                              : '使用此模型',
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () => edit(context, profile),
                        icon: const Icon(Icons.tune, size: 17),
                        label: const Text('配置'),
                      ),
                      IconButton(
                        tooltip: '删除 ${profile.name}',
                        icon: const Icon(Icons.delete_outline, size: 19),
                        onPressed: () async {
                          final confirmed = await showDialog<bool>(
                            context: context,
                            builder: (c) => AlertDialog(
                              title: const Text('删除模型连接？'),
                              content: Text(
                                '将删除“${profile.name}”的配置与密钥，聊天记录会保留。',
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(c, false),
                                  child: const Text('取消'),
                                ),
                                FilledButton(
                                  onPressed: () => Navigator.pop(c, true),
                                  child: const Text('删除'),
                                ),
                              ],
                            ),
                          );
                          if (confirmed == true) {
                            try {
                              await modelSettings.remove(profile.id);
                            } catch (_) {
                              if (context.mounted) toast(context, '删除未完成，请重试');
                            }
                          }
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
          OutlinedButton.icon(
            onPressed: () => edit(context),
            icon: const Icon(Icons.add),
            label: const Text('添加模型连接'),
          ),
        ],
        const SizedBox(height: 18),
        label('密钥单独加密保存在此设备；发送消息时，仅连接你选择的模型服务。', size: 11, color: muted),
        const SizedBox(height: 8),
        label(
          '支持 OpenAI 兼容、Responses、Claude 与 Gemini。图片理解需所选模型和接口支持；语音转写使用手机系统服务。',
          size: 11,
          color: muted,
        ),
      ],
    ),
  );
}

class _ConnectionEditor extends StatefulWidget {
  const _ConnectionEditor({this.profile});
  final ModelConnection? profile;
  @override
  State<_ConnectionEditor> createState() => _ConnectionEditorState();
}

class _ConnectionEditorState extends State<_ConnectionEditor> {
  final form = GlobalKey<FormState>();
  late final name = TextEditingController(text: widget.profile?.name ?? ''),
      address = TextEditingController(text: widget.profile?.address ?? ''),
      model = TextEditingController(text: widget.profile?.model ?? ''),
      keyInput = TextEditingController(),
      maxOutput = TextEditingController(
        text: '${widget.profile?.maxOutput ?? 2048}',
      ),
      timeout = TextEditingController(
        text: '${widget.profile?.timeoutSeconds ?? 120}',
      ),
      contextLimit = TextEditingController(
        text: widget.profile?.contextLimit?.toString() ?? '',
      ),
      temperature = TextEditingController(
        text: widget.profile?.temperature?.toString() ?? '',
      );
  late String provider = widget.profile?.provider ?? providerPresets.first.name,
      auth = widget.profile?.auth ?? 'default',
      tokenParameter = widget.profile?.tokenParameter ?? 'max_tokens';
  late ApiProtocol protocol = widget.profile?.protocol ?? ApiProtocol.chat;
  late bool streaming = widget.profile?.streaming ?? true,
      includeUsage = widget.profile?.includeUsage ?? true;
  bool busy = false, loadingKey = false, hidden = true;
  String? result;
  bool success = false;
  ChatSession? testSession;

  @override
  void initState() {
    super.initState();
    if (widget.profile != null) {
      loadingKey = true;
      modelSettings
          .keyFor(widget.profile!.id)
          .then((value) {
            if (mounted)
              setState(() {
                keyInput.text = value;
                loadingKey = false;
              });
          })
          .catchError((Object _) {
            if (mounted)
              setState(() {
                result = '密钥读取失败，请重新填写。';
                loadingKey = false;
              });
          });
    }
  }

  @override
  void dispose() {
    testSession?.cancel();
    for (final c in [
      name,
      address,
      model,
      keyInput,
      maxOutput,
      timeout,
      contextLimit,
      temperature,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  ModelConnection config() => ModelConnection(
    id:
        widget.profile?.id ??
        'connection-${DateTime.now().microsecondsSinceEpoch}',
    name: name.text.trim().isEmpty ? provider : name.text.trim(),
    provider: provider,
    protocol: protocol,
    address: address.text.trim(),
    model: model.text.trim(),
    auth: auth,
    streaming: streaming,
    includeUsage: includeUsage,
    tokenParameter: tokenParameter,
    maxOutput: int.tryParse(maxOutput.text) ?? 2048,
    timeoutSeconds: int.tryParse(timeout.text) ?? 120,
    contextLimit: int.tryParse(contextLimit.text),
    temperature: double.tryParse(temperature.text),
  );

  Future<void> pickProvider() async {
    final selected = await showModalBottomSheet<ProviderPreset>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (c) => SizedBox(
        height: MediaQuery.sizeOf(c).height * .78,
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.all(20),
              child: Text(
                '选择服务商',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: providerPresets.length,
                itemBuilder: (_, i) {
                  final preset = providerPresets[i];
                  return ListTile(
                    title: Text(preset.name),
                    subtitle: Text(
                      preset.protocol.label,
                      style: const TextStyle(fontSize: 11),
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.pop(c, preset),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
    if (selected == null || !mounted) return;
    setState(() {
      provider = selected.name;
      protocol = selected.protocol;
      address.text = selected.address;
      name.text = selected.name;
      model.clear();
      keyInput.clear();
      auth = provider == 'Azure OpenAI'
          ? 'api-key'
          : ['Ollama', 'LM Studio'].contains(provider)
          ? 'none'
          : 'default';
      tokenParameter = provider == 'OpenAI'
          ? 'max_completion_tokens'
          : 'max_tokens';
      result = null;
    });
  }

  Future<void> fetchModels() async {
    try {
      config().endpoint(models: true);
    } on FormatException catch (e) {
      setState(() {
        result = e.message;
        success = false;
      });
      return;
    }
    setState(() {
      busy = true;
      result = null;
    });
    try {
      final models = await ChatApi().models(config(), keyInput.text);
      if (!mounted) return;
      if (models.isEmpty) throw const ChatFailure('未找到可用模型，请手动填写模型 ID。');
      final selected = await showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (c) => _ModelList(models: models),
      );
      if (selected != null && mounted) setState(() => model.text = selected);
    } catch (e) {
      if (mounted)
        setState(() {
          result = e is ChatFailure ? e.message : '获取失败，可手动填写模型 ID。';
          success = false;
        });
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> testConnection() async {
    if (!form.currentState!.validate()) return;
    setState(() {
      busy = true;
      result = null;
    });
    try {
      final session = ChatApi().start(config(), keyInput.text, [
        {'role': 'user', 'content': '请只回复 OK。'},
      ], '');
      testSession = session;
      var received = false;
      await for (final event in session.events) {
        received = received || event.text.trim().isNotEmpty;
      }
      if (!received) throw const ChatFailure('连接成功但没有收到文字，请检查模型与输出上限。');
      if (mounted)
        setState(() {
          result = '连接成功，已收到模型回复。';
          success = true;
        });
    } catch (e) {
      if (mounted)
        setState(() {
          result = e is ChatFailure ? e.message : '连接失败，请检查配置。';
          success = false;
        });
    } finally {
      testSession = null;
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> save() async {
    if (!form.currentState!.validate()) return;
    setState(() {
      busy = true;
      result = null;
    });
    try {
      await modelSettings.save(config(), keyInput.text);
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted)
        setState(() {
          busy = false;
          success = false;
          result = '保存失败，请重试。密钥不会写入普通配置。';
        });
    }
  }

  Widget field(
    TextEditingController controller,
    String title, {
    String? hint,
    String? note,
    TextInputType? keyboard,
    String? Function(String?)? validator,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: TextFormField(
      controller: controller,
      enabled: !busy && !loadingKey,
      keyboardType: keyboard,
      autocorrect: false,
      decoration: InputDecoration(
        labelText: title,
        hintText: hint,
        helperText: note,
        helperMaxLines: 3,
      ),
      validator: validator,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final note = providerPresets
        .where((p) => p.name == provider)
        .firstOrNull
        ?.note;
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * .92,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 8, 6),
              child: Row(
                children: [
                  Expanded(
                    child: label(
                      widget.profile == null ? '添加模型连接' : '编辑模型连接',
                      size: 20,
                      weight: FontWeight.w600,
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭配置',
                    onPressed: busy ? null : () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Form(
                  key: form,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('服务商'),
                        subtitle: Text(provider),
                        trailing: const Icon(Icons.unfold_more),
                        onTap: busy || loadingKey ? null : pickProvider,
                      ),
                      if (note != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 20),
                          child: label(note, size: 11, color: muted),
                        ),
                      field(name, '连接名称', hint: '例如：日常对话'),
                      DropdownButtonFormField<ApiProtocol>(
                        initialValue: protocol,
                        key: ValueKey('protocol-$protocol'),
                        isExpanded: true,
                        decoration: const InputDecoration(labelText: '接口协议'),
                        items: ApiProtocol.values
                            .map(
                              (p) => DropdownMenuItem(
                                value: p,
                                child: Text(
                                  p.label,
                                  style: const TextStyle(fontSize: 13),
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: busy
                            ? null
                            : (v) => setState(() {
                                protocol = v!;
                                result = null;
                              }),
                      ),
                      const SizedBox(height: 20),
                      field(
                        address,
                        'API 地址',
                        hint: 'https://example.com/v1',
                        keyboard: TextInputType.url,
                        note: '支持基础地址或完整接口地址；系统会保留你的路径前缀。HTTP 适用于可信的本地服务。',
                        validator: (_) {
                          try {
                            config().endpoint();
                            return null;
                          } on FormatException catch (e) {
                            return e.message;
                          }
                        },
                      ),
                      TextFormField(
                        controller: keyInput,
                        obscureText: hidden,
                        enabled: !busy && !loadingKey,
                        autocorrect: false,
                        enableSuggestions: false,
                        decoration: InputDecoration(
                          labelText: loadingKey ? '正在读取密钥…' : 'API Key',
                          helperText: auth == 'none'
                              ? '当前连接不使用密钥。'
                              : '只保存在此设备的加密存储中。',
                          suffixIcon: IconButton(
                            tooltip: hidden ? '显示密钥' : '隐藏密钥',
                            onPressed: () => setState(() => hidden = !hidden),
                            icon: Icon(
                              hidden
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                            ),
                          ),
                        ),
                        validator: (v) =>
                            auth != 'none' && (v?.trim().isEmpty ?? true)
                            ? '请填写 API Key，或在高级设置选择无密钥鉴权'
                            : null,
                      ),
                      const SizedBox(height: 20),
                      field(
                        model,
                        '模型 ID',
                        hint: '填写服务商提供的模型名称',
                        validator: (v) =>
                            v == null || v.trim().isEmpty ? '请填写模型 ID' : null,
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                          onPressed: busy || loadingKey ? null : fetchModels,
                          icon: const Icon(Icons.refresh, size: 17),
                          label: const Text('获取模型列表'),
                        ),
                      ),
                      SwitchListTile.adaptive(
                        contentPadding: EdgeInsets.zero,
                        title: const Text(
                          '流式回复',
                          style: TextStyle(fontSize: 14),
                        ),
                        subtitle: const Text(
                          '边生成边显示内容',
                          style: TextStyle(fontSize: 11),
                        ),
                        value: streaming,
                        onChanged: busy
                            ? null
                            : (v) => setState(() => streaming = v),
                      ),
                      ExpansionTile(
                        tilePadding: EdgeInsets.zero,
                        title: const Text(
                          '高级设置',
                          style: TextStyle(fontSize: 14),
                        ),
                        children: [
                          const SizedBox(height: 12),
                          DropdownButtonFormField<String>(
                            initialValue: auth,
                            key: ValueKey('auth-$auth'),
                            decoration: const InputDecoration(
                              labelText: '鉴权方式',
                            ),
                            isExpanded: true,
                            items:
                                const {
                                      'default': '跟随协议',
                                      'bearer': 'Authorization · Bearer',
                                      'api-key': 'api-key（Azure）',
                                      'x-api-key': 'x-api-key',
                                      'x-goog-api-key': 'x-goog-api-key',
                                      'none': '不使用密钥',
                                    }.entries
                                    .map(
                                      (e) => DropdownMenuItem(
                                        value: e.key,
                                        child: Text(
                                          e.value,
                                          style: const TextStyle(fontSize: 13),
                                        ),
                                      ),
                                    )
                                    .toList(),
                            onChanged: busy
                                ? null
                                : (v) => setState(() => auth = v!),
                          ),
                          const SizedBox(height: 20),
                          field(
                            maxOutput,
                            '最大输出 Token',
                            keyboard: TextInputType.number,
                            validator: (v) {
                              final n = int.tryParse(v ?? '');
                              return n == null || n < 16 || n > 131072
                                  ? '请输入 16–131072 的整数'
                                  : null;
                            },
                          ),
                          field(
                            timeout,
                            '等待超时（秒）',
                            keyboard: TextInputType.number,
                            validator: (v) {
                              final n = int.tryParse(v ?? '');
                              return n == null || n < 15 || n > 600
                                  ? '请输入 15–600 的整数'
                                  : null;
                            },
                          ),
                          field(
                            contextLimit,
                            '上下文容量（可选）',
                            keyboard: TextInputType.number,
                            note: '按模型的实际容量填写，用于底部占比显示；不会自动截断历史。',
                            validator: (v) =>
                                v?.trim().isNotEmpty == true &&
                                    (int.tryParse(v!) == null ||
                                        int.parse(v) <= 0)
                                ? '请输入正整数，或留空'
                                : null,
                          ),
                          field(
                            temperature,
                            '温度（可选）',
                            keyboard: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            note: '留空使用模型默认值，部分推理模型不支持温度参数。',
                            validator: (v) {
                              if (v?.trim().isEmpty ?? true) return null;
                              final n = double.tryParse(v!);
                              return n == null || !n.isFinite || n < 0 || n > 2
                                  ? '请输入 0–2 的数字，或留空'
                                  : null;
                            },
                          ),
                          if (protocol == ApiProtocol.chat) ...[
                            DropdownButtonFormField<String>(
                              initialValue: tokenParameter,
                              decoration: const InputDecoration(
                                labelText: '输出上限参数',
                              ),
                              items:
                                  const {
                                        'max_tokens': 'max_tokens（常见兼容接口）',
                                        'max_completion_tokens':
                                            'max_completion_tokens（OpenAI）',
                                        'none': '不发送此参数',
                                      }.entries
                                      .map(
                                        (e) => DropdownMenuItem(
                                          value: e.key,
                                          child: Text(
                                            e.value,
                                            style: const TextStyle(
                                              fontSize: 11,
                                            ),
                                          ),
                                        ),
                                      )
                                      .toList(),
                              isExpanded: true,
                              onChanged: busy
                                  ? null
                                  : (v) => setState(() => tokenParameter = v!),
                            ),
                            SwitchListTile.adaptive(
                              contentPadding: EdgeInsets.zero,
                              title: const Text(
                                '请求用量统计',
                                style: TextStyle(fontSize: 13),
                              ),
                              subtitle: const Text(
                                '不支持 stream_options 的接口可关闭',
                                style: TextStyle(fontSize: 11),
                              ),
                              value: includeUsage,
                              onChanged: busy
                                  ? null
                                  : (v) => setState(() => includeUsage = v),
                            ),
                          ],
                        ],
                      ),
                      if (result != null)
                        Container(
                          margin: const EdgeInsets.only(top: 16),
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color:
                                (success
                                        ? green
                                        : Theme.of(context).colorScheme.error)
                                    .withValues(alpha: .08),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                success
                                    ? Icons.check_circle_outline
                                    : Icons.info_outline,
                                size: 18,
                                color: success
                                    ? green
                                    : Theme.of(context).colorScheme.error,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  result!,
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ),
                            ],
                          ),
                        ),
                      const SizedBox(height: 18),
                      label(
                        '测试连接会向此地址发送一条简短消息，并按服务商规则计费。',
                        size: 11,
                        color: muted,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (busy) const LinearProgressIndicator(minHeight: 2),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: busy || loadingKey ? null : testConnection,
                      child: const Text('测试连接'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: busy || loadingKey ? null : save,
                      child: const Text('保存连接'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModelList extends StatefulWidget {
  const _ModelList({required this.models});
  final List<String> models;
  @override
  State<_ModelList> createState() => _ModelListState();
}

class _ModelListState extends State<_ModelList> {
  String query = '';
  @override
  Widget build(BuildContext context) {
    final models = widget.models
        .where((m) => m.toLowerCase().contains(query.toLowerCase()))
        .toList();
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * .75,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(20),
            child: TextField(
              autofocus: false,
              decoration: const InputDecoration(
                labelText: '搜索模型',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (v) => setState(() => query = v),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: models.length,
              itemBuilder: (c, i) => ListTile(
                title: Text(models[i], style: const TextStyle(fontSize: 13)),
                onTap: () => Navigator.pop(context, models[i]),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

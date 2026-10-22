import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'speech_settings.dart';
import 'voice_call_session.dart';
import 'widgets.dart';

class SpeechSettingsPage extends StatefulWidget {
  const SpeechSettingsPage({super.key, this.settings});
  final SpeechSettings? settings;
  @override
  State<SpeechSettingsPage> createState() => _SpeechSettingsPageState();
}

class _SpeechSettingsPageState extends State<SpeechSettingsPage>
    with WidgetsBindingObserver {
  SpeechSettings get model => widget.settings ?? speechSettings;
  late final VoiceCallSession preview = VoiceCallSession(speech: model);
  bool busy = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) preview.stopPreview();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    preview.dispose();
    super.dispose();
  }

  Future<void> action(Future<void> Function() work) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await work();
    } catch (_) {
      if (mounted) toast(context, '语音配置未保存，请重试。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> edit([SpeechProfile? profile]) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SpeechEditor(settings: model, profile: profile),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: model,
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Pane(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '声音合成',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              const Text(
                '选择通话使用的声音，也可以连接自己的语音服务。',
                style: TextStyle(fontSize: 12, height: 1.6),
              ),
              const SizedBox(height: 12),
              for (final p in model.profiles)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    p.id == model.activeId
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    size: 22,
                  ),
                  title: Text(p.name, style: const TextStyle(fontSize: 14)),
                  subtitle: Text(
                    '${p.provider.label}${p.voice.isEmpty ? '' : ' · ${p.voice}'}',
                    style: const TextStyle(fontSize: 11),
                  ),
                  onTap: busy ? null : () => action(() => model.select(p.id)),
                  trailing: IconButton(
                    tooltip: '编辑 ${p.name}',
                    onPressed: busy ? null : () => edit(p),
                    icon: const Icon(Icons.tune, size: 20),
                  ),
                ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: busy ? null : () => edit(),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('添加语音服务'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Pane(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '听听这个声音',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              Text(
                '当前使用：${model.active.name}',
                style: const TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: busy || kIsWeb
                    ? null
                    : () => action(() async {
                        await preview.previewVoice();
                        if (mounted && preview.error != null)
                          toast(context, preview.error!);
                      }),
                icon: busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.volume_up_outlined, size: 18),
                label: Text(busy ? '正在处理…' : '试听声音'),
              ),
              if (busy)
                TextButton(
                  onPressed: preview.stopPreview,
                  child: const Text('停止试听'),
                ),
              if (kIsWeb)
                const Text(
                  '请在 Android App 中试听。',
                  style: TextStyle(fontSize: 12),
                ),
              const SizedBox(height: 8),
              const Text(
                '云端合成会将朗读文字发给你选择的服务，按该服务的账号计费；不会自动使用中转站额度。密钥与自定义模板仅保存在本机安全存储。',
                style: TextStyle(fontSize: 11, height: 1.6),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        const ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.mic_none),
          title: Text('语音识别'),
          subtitle: Text('当前使用 Android 系统识别。首次收音时请求麦克风权限；服务可能联网。'),
        ),
        if (model.error != null) Text(model.error!),
      ],
    ),
  );
}

class SpeechEditor extends StatefulWidget {
  const SpeechEditor({super.key, required this.settings, this.profile});
  final SpeechSettings settings;
  final SpeechProfile? profile;
  @override
  State<SpeechEditor> createState() => _SpeechEditorState();
}

class _SpeechEditorState extends State<SpeechEditor> {
  final form = GlobalKey<FormState>();
  late SpeechProvider provider;
  late final TextEditingController name,
      endpoint,
      keyText,
      model,
      voice,
      headers,
      body,
      path,
      instructions;
  late String method, response;
  late double speed;
  bool busy = false, showKey = false;
  String? error;
  @override
  void initState() {
    super.initState();
    final p =
        widget.profile ??
        const SpeechProfile(
          id: 'new',
          name: '自定义语音',
          provider: SpeechProvider.openai,
        );
    provider = p.provider;
    method = p.method;
    response = p.response;
    speed = p.speed;
    name = TextEditingController(text: p.name);
    endpoint = TextEditingController(text: p.endpoint);
    keyText = TextEditingController(text: p.apiKey);
    model = TextEditingController(text: p.model);
    voice = TextEditingController(text: p.voice);
    headers = TextEditingController(text: p.headers);
    body = TextEditingController(text: p.body);
    path = TextEditingController(text: p.responsePath);
    instructions = TextEditingController(text: p.instructions);
    if (widget.profile == null) preset(provider);
  }

  void preset(SpeechProvider value) {
    provider = value;
    name.text = value.label;
    speed = 1;
    keyText.clear();
    instructions.clear();
    final preset = switch (value) {
      SpeechProvider.openai => (
        'https://api.openai.com/v1/audio/speech',
        'gpt-4o-mini-tts',
        'alloy',
      ),
      SpeechProvider.elevenlabs => (
        'https://api.elevenlabs.io/v1/text-to-speech/{voice}',
        'eleven_multilingual_v2',
        '',
      ),
      SpeechProvider.azure => (
        'https://eastasia.tts.speech.microsoft.com/cognitiveservices/v1',
        '',
        'zh-CN-XiaoxiaoNeural',
      ),
      _ => ('', '', ''),
    };
    endpoint.text = preset.$1;
    model.text = preset.$2;
    voice.text = preset.$3;
  }

  @override
  void dispose() {
    for (final c in [
      name,
      endpoint,
      keyText,
      model,
      voice,
      headers,
      body,
      path,
      instructions,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Widget field(
    TextEditingController c,
    String title, {
    String? hint,
    int lines = 1,
    bool secret = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: TextFormField(
      controller: c,
      obscureText: secret && !showKey,
      maxLines: lines,
      autocorrect: false,
      enableSuggestions: !secret,
      decoration: InputDecoration(
        labelText: title,
        helperText: hint,
        helperMaxLines: 3,
        alignLabelWithHint: lines > 1,
        suffixIcon: secret
            ? IconButton(
                tooltip: showKey ? '隐藏密钥' : '显示密钥',
                onPressed: () => setState(() => showKey = !showKey),
                icon: Icon(
                  showKey
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                ),
              )
            : null,
      ),
    ),
  );
  Future<void> save() async {
    setState(() => error = null);
    try {
      final p = SpeechProfile(
        id:
            widget.profile?.id ??
            'speech-${DateTime.now().microsecondsSinceEpoch}',
        name: name.text.trim(),
        provider: provider,
        endpoint: endpoint.text.trim(),
        apiKey: keyText.text.trim(),
        model: model.text.trim(),
        voice: voice.text.trim(),
        speed: speed,
        method: method,
        headers: headers.text,
        body: body.text,
        response: response,
        responsePath: path.text.trim(),
        instructions: instructions.text.trim(),
      );
      p.validate();
      setState(() => busy = true);
      await widget.settings.save(p);
      if (mounted) Navigator.pop(context);
    } catch (failure) {
      if (mounted)
        setState(
          () => error = failure is FormatException
              ? failure.message
              : '保存失败，原配置已保留，请重试。',
        );
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.profile == null ? '添加语音服务' : '编辑语音服务')),
    bottomNavigationBar: SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          8,
          16,
          12 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: FilledButton(
          onPressed: busy ? null : save,
          child: Text(busy ? '正在保存…' : '保存并使用'),
        ),
      ),
    ),
    body: Form(
      key: form,
      child: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          DropdownButtonFormField<SpeechProvider>(
            initialValue: provider,
            isExpanded: true,
            decoration: const InputDecoration(labelText: '服务类型'),
            items: [
              for (final p in SpeechProvider.values)
                DropdownMenuItem(value: p, child: Text(p.label)),
            ],
            onChanged: busy || widget.profile?.id == 'system'
                ? null
                : (p) => setState(() => preset(p!)),
          ),
          const SizedBox(height: 20),
          field(name, '连接名称'),
          if (provider != SpeechProvider.system) ...[
            field(
              endpoint,
              '完整合成接口地址',
              hint: provider == SpeechProvider.azure
                  ? '请将 eastasia 替换为你资源所在区域。'
                  : '支持中转地址、局域网服务；填写完整路径。',
            ),
            field(
              keyText,
              'API Key',
              secret: true,
              hint: '密钥仅保存到本机安全存储，不包含在聊天备份中。',
            ),
            if (provider != SpeechProvider.azure)
              field(
                model,
                '模型 ID',
                hint: provider == SpeechProvider.custom
                    ? '可选，模板中用 {model} 引用。'
                    : null,
              ),
          ],
          field(
            voice,
            '音色 ID',
            hint: provider == SpeechProvider.system
                ? '留空跟随系统默认音色。'
                : '填写服务提供的音色名称或 ID。',
          ),
          Row(
            children: [
              const Text('语速'),
              const Spacer(),
              Text('${speed.toStringAsFixed(2)}×'),
            ],
          ),
          Slider(
            value: speed,
            min: provider == SpeechProvider.elevenlabs ? 0.7 : 0.5,
            max: provider == SpeechProvider.elevenlabs ? 1.2 : 2,
            divisions: 30,
            onChanged: busy ? null : (v) => setState(() => speed = v),
          ),
          if (provider == SpeechProvider.openai)
            field(
              instructions,
              '声音风格（可选）',
              hint: '例如：自然、温柔地说话。需要模型支持 instructions 参数。',
              lines: 2,
            ),
          if (provider == SpeechProvider.custom) ...[
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              isExpanded: true,
              initialValue: method,
              decoration: const InputDecoration(labelText: '请求方式'),
              items: [
                for (final m in ['POST', 'GET'])
                  DropdownMenuItem(value: m, child: Text(m)),
              ],
              onChanged: (v) => setState(() => method = v!),
            ),
            const SizedBox(height: 18),
            field(
              headers,
              '请求头 JSON',
              hint: '可用 {key} 引用密钥，例如 {"Authorization":"Bearer {key}"}。',
              lines: 3,
            ),
            if (method == 'POST')
              field(
                body,
                '请求体 JSON 模板',
                hint: '支持 {text}、{model}、{voice}、{speed}。变量安全替换后再编码为 JSON。',
                lines: 5,
              ),
            DropdownButtonFormField<String>(
              isExpanded: true,
              initialValue: response,
              decoration: const InputDecoration(labelText: '返回内容'),
              items: const [
                DropdownMenuItem(value: 'audio', child: Text('直接返回音频')),
                DropdownMenuItem(
                  value: 'base64',
                  child: Text('JSON 中的 Base64 音频'),
                ),
                DropdownMenuItem(value: 'hex', child: Text('JSON 中的 Hex 音频')),
                DropdownMenuItem(value: 'url', child: Text('JSON 中的音频地址')),
              ],
              onChanged: (v) => setState(() => response = v!),
            ),
            const SizedBox(height: 18),
            if (response != 'audio')
              field(path, '音频字段路径', hint: '例如 data.audio；数组使用 data.0.audio。'),
            const Text(
              '音频请使用 MP3、WAV 等 Android 可播放的格式；原始 PCM 需由服务封装为 WAV。GET 地址可使用 {text} 等变量。',
              style: TextStyle(fontSize: 12, height: 1.6),
            ),
          ],
          if (error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (widget.profile != null && widget.profile!.id != 'system')
            TextButton.icon(
              onPressed: busy
                  ? null
                  : () async {
                      final confirmed = await showDialog<bool>(
                        context: context,
                        builder: (c) => AlertDialog(
                          title: const Text('删除语音连接？'),
                          content: const Text('仅删除此设备保存的配置。'),
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
                      if (confirmed == true && mounted) {
                        setState(() => busy = true);
                        try {
                          await widget.settings.remove(widget.profile!.id);
                          if (mounted) Navigator.pop(context);
                        } catch (_) {
                          if (mounted) setState(() => error = '删除失败，请重试。');
                        } finally {
                          if (mounted) setState(() => busy = false);
                        }
                      }
                    },
              icon: const Icon(Icons.delete_outline),
              label: const Text('删除这个连接'),
            ),
        ],
      ),
    ),
  );
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'speech_recognition_settings.dart';
import 'speech_input_session.dart';
import 'speech_settings.dart';

class RecognitionSettingsPanel extends StatelessWidget {
  const RecognitionSettingsPanel({super.key, required this.settings});
  final SpeechSettings settings;
  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: const Icon(Icons.mic_none),
    title: const Text('语音输入与识别'),
    subtitle: Text(
      '${settings.recognition.label} · ${settings.recognition.language}\n点此配置或测试识别；与声音合成分别设置。',
    ),
    trailing: const Icon(Icons.chevron_right),
    onTap: () => Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RecognitionSettingsPage(settings: settings),
      ),
    ),
  );
}

class RecognitionSettingsPage extends StatefulWidget {
  const RecognitionSettingsPage({super.key, required this.settings});
  final SpeechSettings settings;
  @override
  State<RecognitionSettingsPage> createState() =>
      _RecognitionSettingsPageState();
}

class _RecognitionSettingsPageState extends State<RecognitionSettingsPage>
    with WidgetsBindingObserver {
  late RecognitionProvider provider;
  late final TextEditingController endpoint,
      keyText,
      model,
      language,
      headers,
      fields,
      audioField,
      path,
      silence,
      timeout;
  late bool offline;
  late String transport;
  late final SpeechInputSession input = SpeechInputSession(
    settings: widget.settings,
  );
  bool busy = false, saving = false;
  String? error, result;
  Map<dynamic, dynamic>? status;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final p = widget.settings.recognition;
    provider = p.provider;
    offline = p.preferOnDevice;
    transport = p.transport;
    endpoint = TextEditingController(text: p.endpoint);
    keyText = TextEditingController(text: p.apiKey);
    model = TextEditingController(text: p.model);
    language = TextEditingController(text: p.language);
    headers = TextEditingController(text: p.headers);
    fields = TextEditingController(text: p.fields);
    audioField = TextEditingController(text: p.audioField);
    path = TextEditingController(text: p.responsePath);
    silence = TextEditingController(text: '${p.silenceMillis}');
    timeout = TextEditingController(text: '${p.timeoutSeconds}');
    _status();
  }

  Future<void> _status() async {
    try {
      final value = await const MethodChannel(
        'skivu/voice_call',
      ).invokeMapMethod('recognitionStatus');
      if (mounted) setState(() => status = value);
    } catch (_) {
      /* Status is informational; explicit recognition reports errors. */
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed)
      input.cancel();
    else
      _status();
  }

  RecognitionProfile value() => RecognitionProfile(
    provider: provider,
    endpoint: endpoint.text.trim(),
    apiKey: keyText.text,
    model: model.text.trim(),
    language: language.text.trim(),
    preferOnDevice: offline,
    headers: headers.text,
    fields: fields.text,
    audioField: audioField.text.trim(),
    transport: transport,
    responsePath: path.text.trim(),
    silenceMillis: int.tryParse(silence.text) ?? -1,
    timeoutSeconds: int.tryParse(timeout.text) ?? -1,
  );
  Future<bool> save() async {
    if (saving) return false;
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await widget.settings.saveRecognition(value());
      return true;
    } catch (e) {
      if (mounted)
        setState(
          () => error = e is FormatException ? e.message : '识别配置未能保存，请重试。',
        );
      return false;
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> test() async {
    if (!await save() || !mounted) return;
    setState(() {
      busy = true;
      error = null;
      result = null;
    });
    try {
      final text = await input.listen();
      if (mounted) setState(() => result = text);
    } catch (e) {
      if (mounted)
        setState(
          () => error = e is FormatException ? e.message : '识别未完成，请检查服务和网络。',
        );
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget field(
    TextEditingController c,
    String label, {
    bool secret = false,
    int lines = 1,
    String? hint,
    bool number = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: TextField(
      controller: c,
      enabled: !busy && !saving,
      obscureText: secret,
      minLines: lines,
      maxLines: lines == 1 ? 1 : null,
      keyboardType: number ? TextInputType.number : null,
      decoration: InputDecoration(
        labelText: label,
        helperText: hint,
        helperMaxLines: 4,
      ),
    ),
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('语音输入与识别')),
    body: SafeArea(
      child: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                DropdownButtonFormField<RecognitionProvider>(
                  initialValue: provider,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: '识别方式'),
                  items: RecognitionProvider.values
                      .map(
                        (v) => DropdownMenuItem(
                          value: v,
                          child: Text(RecognitionProfile(provider: v).label),
                        ),
                      )
                      .toList(),
                  onChanged: busy ? null : (v) => setState(() => provider = v!),
                ),
                const SizedBox(height: 16),
                field(language, '识别语言', hint: '例如 zh-CN、en-US；留空跟随系统。'),
                if (provider == RecognitionProvider.system) ...[
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: offline,
                    onChanged: busy ? null : (v) => setState(() => offline = v),
                    title: const Text('优先使用本机识别'),
                    subtitle: const Text('系统支持时使用本机识别；否则使用系统默认服务。语言资源由系统服务管理。'),
                  ),
                  if (status != null)
                    Text(
                      '系统识别：${status!['systemAvailable'] == true ? '可用' : '未安装服务'} · 本机识别：${status!['onDeviceAvailable'] == true ? '可用' : '不可用'}\n麦克风：${status!['microphoneGranted'] == true ? '已授权' : '首次使用时请求授权'}',
                    ),
                ] else ...[
                  field(
                    endpoint,
                    '识别接口完整地址',
                    hint: '填写实际转写接口，例如服务的 /v1/audio/transcriptions。',
                  ),
                  field(keyText, 'API 密钥', secret: true),
                  field(model, '识别模型 ID'),
                  field(
                    silence,
                    '说完后自动结束的静音时间（毫秒）',
                    number: true,
                    hint: '默认 1200；0 为手动结束录音。',
                  ),
                  field(timeout, '请求超时（秒）', number: true, hint: '0 不额外设置请求超时。'),
                  if (provider == RecognitionProvider.custom) ...[
                    DropdownButtonFormField<String>(
                      initialValue: transport,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: '上传格式'),
                      items: const [
                        DropdownMenuItem(
                          value: 'multipart',
                          child: Text('multipart 文件上传'),
                        ),
                        DropdownMenuItem(
                          value: 'json',
                          child: Text('JSON Base64 音频'),
                        ),
                      ],
                      onChanged: busy
                          ? null
                          : (v) => setState(() => transport = v!),
                    ),
                    const SizedBox(height: 16),
                    field(audioField, '音频字段名'),
                    field(headers, '自定义请求头（JSON）', lines: 2),
                    field(
                      fields,
                      '附加字段（JSON）',
                      lines: 3,
                      hint: '支持 {model} 和 {language}，音频由应用写入音频字段。',
                    ),
                  ],
                  field(path, '文字字段路径', hint: '如 text、data.text；留空表示响应正文就是文字。'),
                  const Text(
                    '仅在选择此服务并开始识别后，将本次录音发送到该地址。密钥保存在本机安全存储。取消会终止请求并清理临时录音。',
                  ),
                ],
                const SizedBox(height: 20),
                AnimatedBuilder(
                  animation: input,
                  builder: (c, _) => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      FilledButton.icon(
                        onPressed: saving
                            ? null
                            : busy
                            ? input.finish
                            : test,
                        icon: Icon(
                          busy ? Icons.stop_circle_outlined : Icons.mic_none,
                        ),
                        label: Text(
                          busy
                              ? (input.phase == 'transcribing'
                                    ? '正在识别…'
                                    : '说完了，结束并识别')
                              : '测试语音识别',
                        ),
                      ),
                      if (busy)
                        TextButton(
                          onPressed: input.cancel,
                          child: const Text('取消本次识别'),
                        ),
                      if (input.partial.isNotEmpty) Text(input.partial),
                    ],
                  ),
                ),
                if (result != null) SelectableText(result!),
                if (error != null)
                  Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: busy || saving
                    ? null
                    : () async {
                        if (await save() && context.mounted)
                          Navigator.pop(context);
                      },
                child: const Text('保存并使用'),
              ),
            ),
          ),
        ],
      ),
    ),
  );
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    input.dispose();
    for (final c in [
      endpoint,
      keyText,
      model,
      language,
      headers,
      fields,
      audioField,
      path,
      silence,
      timeout,
    ]) {
      c.dispose();
    }
    super.dispose();
  }
}

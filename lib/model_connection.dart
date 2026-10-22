enum ApiProtocol {
  chat('OpenAI 兼容', 'Chat Completions'),
  responses('OpenAI Responses', 'Responses API'),
  anthropic('Anthropic / Claude', 'Messages API'),
  gemini('Google Gemini', 'Generate Content');

  const ApiProtocol(this.label, this.detail);
  final String label, detail;
}

class ProviderPreset {
  const ProviderPreset(this.name, this.protocol, this.address, this.note);
  final String name, address, note;
  final ApiProtocol protocol;
}

// Provider names are configuration choices, not implementations from another app.
final providerPresets = <ProviderPreset>[
  ProviderPreset('自定义兼容接口', ApiProtocol.chat, '', '填写服务商提供的 API 地址与模型 ID。'),
  ProviderPreset(
    'OpenAI',
    ApiProtocol.chat,
    'https://api.openai.com/v1',
    '使用 API 平台的密钥，模型名称以账户权限为准。',
  ),
  ProviderPreset(
    'OpenAI Responses',
    ApiProtocol.responses,
    'https://api.openai.com/v1',
    '支持 Responses 的服务可选此协议。',
  ),
  ProviderPreset(
    'Anthropic',
    ApiProtocol.anthropic,
    'https://api.anthropic.com/v1',
    '使用 Claude API 密钥，填写完整模型 ID。',
  ),
  ProviderPreset(
    'Google Gemini',
    ApiProtocol.gemini,
    'https://generativelanguage.googleapis.com/v1beta',
    '使用 Google AI Studio 的 API Key。',
  ),
  ProviderPreset(
    'DeepSeek',
    ApiProtocol.chat,
    'https://api.deepseek.com/v1',
    '模型 ID 以 DeepSeek 控制台或中转服务为准。',
  ),
  ProviderPreset(
    '阿里云百炼',
    ApiProtocol.chat,
    'https://dashscope.aliyuncs.com/compatible-mode/v1',
    '默认中国内地地址；其他地域请按控制台修改。',
  ),
  ProviderPreset(
    '硅基流动',
    ApiProtocol.chat,
    'https://api.siliconflow.cn/v1',
    '填写平台提供的完整模型路径。',
  ),
  ProviderPreset(
    'OpenRouter',
    ApiProtocol.chat,
    'https://openrouter.ai/api/v1',
    '模型 ID 通常包含厂商前缀。',
  ),
  ProviderPreset(
    'xAI',
    ApiProtocol.chat,
    'https://api.x.ai/v1',
    '使用 xAI API 密钥与可用模型 ID。',
  ),
  ProviderPreset(
    'Ollama',
    ApiProtocol.chat,
    'http://127.0.0.1:11434/v1',
    '电脑上的服务请改为电脑局域网 IP；本地服务可不填密钥。',
  ),
  ProviderPreset(
    'LM Studio',
    ApiProtocol.chat,
    'http://127.0.0.1:1234/v1',
    '先开启 Local Server；手机连接电脑时填写电脑局域网 IP。',
  ),
  ProviderPreset(
    'Azure OpenAI',
    ApiProtocol.chat,
    '',
    '填写完整部署接口地址及 api-version 查询参数，鉴权选择 api-key。',
  ),
  for (final name in [
    '百度千帆',
    '讯飞星火',
    '智谱 AI',
    '百川',
    '月之暗面',
    '小米 MiMo',
    'Mistral',
    '心流 iFlow',
    'OpenCode',
    '4Router',
    'Nous Portal',
    '无问芯穹',
    '支付宝百灵',
    '豆包 / 火山方舟',
    'NVIDIA',
    'PPInfra',
    'Novita AI',
    'MiniMax',
  ])
    ProviderPreset(
      name,
      ApiProtocol.chat,
      '',
      '选择该平台的 OpenAI 兼容接口，按其控制台填写地址和模型 ID。',
    ),
];

class ModelConnection {
  const ModelConnection({
    required this.id,
    required this.name,
    required this.provider,
    required this.protocol,
    required this.address,
    required this.model,
    this.auth = 'default',
    this.streaming = true,
    this.includeUsage = true,
    this.maxOutput = 2048,
    this.timeoutSeconds = 120,
    this.contextLimit,
    this.temperature,
    this.tokenParameter = 'max_tokens',
    this.credentialId,
  });
  final String id, name, provider, address, model, auth, tokenParameter;
  final String? credentialId;
  final ApiProtocol protocol;
  final bool streaming, includeUsage;
  final int maxOutput, timeoutSeconds;
  final int? contextLimit;
  final double? temperature;

  Uri endpoint({bool models = false}) {
    final uri = Uri.tryParse(address.trim());
    if (uri == null ||
        !['https', 'http'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      throw const FormatException('请填写有效的 HTTPS API 地址，不要在地址中填写密钥。');
    }
    if (uri.queryParameters.keys.any(
      (key) => [
        'key',
        'api_key',
        'api-key',
        'token',
        'access_token',
      ].contains(key.toLowerCase()),
    )) {
      throw const FormatException('请将密钥填写到 API Key 栏，而不是 API 地址中。');
    }
    final path = uri.path.replaceFirst(RegExp(r'/+$'), '');
    final suffix = switch (protocol) {
      ApiProtocol.chat => '/chat/completions',
      ApiProtocol.responses => '/responses',
      ApiProtocol.anthropic => '/messages',
      ApiProtocol.gemini =>
        '/models/${Uri.encodeComponent(model.replaceFirst('models/', ''))}:${streaming ? 'streamGenerateContent' : 'generateContent'}',
    };
    var base = path;
    for (final ending in ['/chat/completions', '/responses', '/messages']) {
      if (base.endsWith(ending))
        base = base.substring(0, base.length - ending.length);
    }
    if (protocol == ApiProtocol.gemini) {
      base = base.replaceFirst(
        RegExp(r'/models/[^/]+:(streamGenerateContent|generateContent)$'),
        '',
      );
    }
    if (base.isEmpty) base = protocol == ApiProtocol.gemini ? '/v1beta' : '/v1';
    final query = Map<String, String>.from(uri.queryParameters);
    if (protocol == ApiProtocol.gemini && streaming && !models)
      query['alt'] = 'sse';
    // replace(path:) receives an encoded URI path, preserving provider prefixes.
    return uri.replace(
      path: '$base${models ? '/models' : suffix}',
      queryParameters: query.isEmpty ? null : query,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'provider': provider,
    'protocol': protocol.name,
    'address': address,
    'model': model,
    'auth': auth,
    'streaming': streaming,
    'includeUsage': includeUsage,
    'maxOutput': maxOutput,
    'timeoutSeconds': timeoutSeconds,
    'contextLimit': contextLimit,
    'temperature': temperature,
    'tokenParameter': tokenParameter,
    'credentialId': credentialId,
  };

  factory ModelConnection.fromJson(Map<String, dynamic> raw) => ModelConnection(
    id: raw['id'] as String,
    name: raw['name'] as String,
    provider: raw['provider'] as String,
    protocol: ApiProtocol.values.byName(raw['protocol'] as String),
    address: raw['address'] as String,
    model: raw['model'] as String,
    auth: raw['auth'] as String? ?? 'default',
    streaming: raw['streaming'] as bool? ?? true,
    includeUsage: raw['includeUsage'] as bool? ?? true,
    maxOutput: (raw['maxOutput'] as int? ?? 2048).clamp(16, 131072),
    timeoutSeconds: (raw['timeoutSeconds'] as int? ?? 120).clamp(15, 600),
    contextLimit: raw['contextLimit'] as int?,
    temperature: (raw['temperature'] as num?)?.toDouble(),
    tokenParameter: raw['tokenParameter'] as String? ?? 'max_tokens',
    credentialId: raw['credentialId'] as String?,
  );
}

import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'model_connection.dart';
import 'context_budget.dart';

class ChatFailure implements Exception {
  const ChatFailure(this.message, {this.code});
  final String message;
  final String? code;
  @override
  String toString() => message;
}

class ApiUsage {
  const ApiUsage({this.input, this.output, this.cached});
  final int? input, output, cached;
  ApiUsage merge(ApiUsage other) => ApiUsage(
    input: other.input ?? input,
    output: other.output ?? output,
    cached: other.cached ?? cached,
  );
}

class ChatEvent {
  const ChatEvent({
    this.notice,
    this.text = '',
    this.thinking = '',
    this.usage,
    this.done = false,
    this.limited = false,
  });
  final String? notice;
  final String text, thinking;
  final ApiUsage? usage;
  final bool done, limited;
}

class ChatApi {
  ChatApi({http.Client Function()? clientFactory})
    : _clientFactory = clientFactory ?? http.Client.new;
  final http.Client Function() _clientFactory;

  ChatSession start(
    ModelConnection config,
    String key,
    List<Map<String, String>> history,
    String system,
  ) => ChatSession(_clientFactory(), config, key, history, system);

  Future<List<String>> models(ModelConnection config, String key) async {
    final client = _clientFactory();
    try {
      final request = http.Request('GET', config.endpoint(models: true))
        ..followRedirects = false
        ..headers.addAll(_headers(config, key));
      final response = await http.Response.fromStream(
        await client.send(request).timeout(const Duration(seconds: 20)),
      ).timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) throw _httpError(response.statusCode);
      final raw =
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final entries = raw['data'] ?? raw['models'];
      if (entries is! List) throw const ChatFailure('该服务没有返回模型列表，请手动填写模型 ID。');
      return entries
          .whereType<Map>()
          .map(
            (m) =>
                (m['id'] ?? m['name'])?.toString().replaceFirst(
                  'models/',
                  '',
                ) ??
                '',
          )
          .where((s) => s.isNotEmpty)
          .toSet()
          .toList()
        ..sort();
    } on ChatFailure {
      rethrow;
    } catch (_) {
      throw const ChatFailure('无法获取模型列表，可手动填写模型 ID。');
    } finally {
      client.close();
    }
  }
}

Map<String, String> _headers(ModelConnection config, String key) {
  final headers = <String, String>{
    'Content-Type': 'application/json',
    'Accept': config.streaming ? 'text/event-stream' : 'application/json',
  };
  final auth = config.auth == 'default'
      ? switch (config.protocol) {
          ApiProtocol.anthropic => 'x-api-key',
          ApiProtocol.gemini => 'x-goog-api-key',
          _ => 'bearer',
        }
      : config.auth;
  if (key.trim().isNotEmpty && auth != 'none') {
    headers[auth == 'bearer' ? 'Authorization' : auth] = auth == 'bearer'
        ? 'Bearer ${key.trim()}'
        : key.trim();
  }
  if (config.protocol == ApiProtocol.anthropic) {
    headers['anthropic-version'] = '2023-06-01';
    if (kIsWeb) headers['anthropic-dangerous-direct-browser-access'] = 'true';
  }
  return headers;
}

ChatFailure _httpError(int status) => ChatFailure(switch (status) {
  400 => '请求参数不被服务支持。请检查协议、模型 ID 和高级选项。',
  401 || 403 => '鉴权失败。请检查 API Key、账户权限和服务地址。',
  404 => '找不到接口或模型。请检查 API 地址、协议及模型 ID。',
  408 || 504 => '服务响应超时，请稍后重试。',
  413 => '对话内容过长，请新建会话或减少上下文。',
  429 => '请求受限或额度不足，请检查账户后重试。',
  >= 500 => '模型服务暂时不可用（$status），请稍后重试。',
  _ => '请求失败（$status），请检查接口配置。',
});

ChatFailure _accountHttpError(int status) => switch (status) {
  400 => const ChatFailure('对话请求未被支持，请尝试新建会话或切换模型。'),
  401 => const ChatFailure('账号或模型服务验证未通过，请同步账号或切换模型后重试。'),
  403 => const ChatFailure('账号暂时无法使用此模型，请检查额度、订阅与模型权限。'),
  _ => _httpError(status),
};

class ChatSession {
  ChatSession(this._client, this.config, this._key, this.history, this.system)
    : _funding = 'relay',
      _betaHeaders = null,
      _fixedPath = null;
  ChatSession.beta(
    this._client,
    this.config,
    this.history,
    this.system,
    this._betaHeaders,
  ) : _funding = 'relay',
      _key = '',
      _fixedPath = config.protocol == ApiProtocol.responses
          ? '/api/app-beta/responses'
          : '/api/app-beta/chat/completions';
  ChatSession.account(
    this._client,
    this.config,
    this.history,
    this.system,
    String token, {
    String funding = 'relay',
  }) : _funding = funding,
       _key = '',
       _betaHeaders = ((_) async => {'Authorization': 'AppAccount $token'}),
       _fixedPath = config.protocol == ApiProtocol.responses
           ? '/api/app-account/responses'
           : '/api/app-account/chat/completions';
  final String _funding;
  final String? _fixedPath;
  final Future<Map<String, String>> Function(String body)? _betaHeaders;
  final http.Client _client;
  final ModelConnection config;
  final String _key, system;
  final List<Map<String, String>> history;
  final _abort = Completer<void>();
  bool cancelled = false;

  void cancel() {
    cancelled = true;
    if (!_abort.isCompleted) _abort.complete();
    _client.close();
  }

  Map<String, dynamic> _body(List<Map<String, String>> history) {
    Map<String, dynamic> wire(
      Map<String, String> message,
      ApiProtocol protocol,
    ) {
      final image = message['image'], text = message['content'] ?? '';
      if (image == null) return {'role': message['role'], 'content': text};
      final match = RegExp(
        r'^data:(image/(?:png|jpeg|webp));base64,([A-Za-z0-9+/=]+)$',
      ).firstMatch(image);
      if (match == null || image.length > 850000)
        throw const ChatFailure('图片数据无效，请重新选择。');
      return {
        'role': message['role'],
        'content': switch (protocol) {
          ApiProtocol.responses => [
            {'type': 'input_text', 'text': text},
            {'type': 'input_image', 'image_url': image},
          ],
          ApiProtocol.anthropic => [
            {'type': 'text', 'text': text},
            {
              'type': 'image',
              'source': {
                'type': 'base64',
                'media_type': match.group(1),
                'data': match.group(2),
              },
            },
          ],
          _ => [
            {'type': 'text', 'text': text},
            {
              'type': 'image_url',
              'image_url': {'url': image},
            },
          ],
        },
      };
    }

    final messages = [
      if (system.trim().isNotEmpty) {'role': 'system', 'content': system},
      ...history.map((m) => wire(m, ApiProtocol.chat)),
    ];
    final temperature = config.temperature;
    if (_betaHeaders != null && config.protocol == ApiProtocol.responses)
      return {
        'model': config.model,
        if (_funding == 'beta') 'funding': 'beta',
        'input': history.map((m) => wire(m, ApiProtocol.responses)).toList(),
        'instructions': system,
        'stream': config.streaming,
        'max_output_tokens': config.maxOutput.clamp(1, 4096),
        'store': false,
      };
    if (_betaHeaders != null)
      return {
        'model': config.model,
        if (_funding == 'beta') 'funding': 'beta',
        'messages': messages,
        'stream': config.streaming,
        'max_tokens': config.maxOutput.clamp(1, 4096),
      };
    return switch (config.protocol) {
      ApiProtocol.chat => {
        'model': config.model,
        'messages': messages,
        'stream': config.streaming,
        if (config.tokenParameter != 'none')
          config.tokenParameter: config.maxOutput,
        if (config.streaming && config.includeUsage)
          'stream_options': {'include_usage': true},
        if (temperature != null) 'temperature': temperature,
      },
      ApiProtocol.responses => {
        'model': config.model,
        'input': history.map((m) => wire(m, ApiProtocol.responses)).toList(),
        if (system.trim().isNotEmpty) 'instructions': system,
        'stream': config.streaming,
        'max_output_tokens': config.maxOutput,
        'store': false,
        if (temperature != null) 'temperature': temperature,
      },
      ApiProtocol.anthropic => {
        'model': config.model,
        'messages': history.map((m) => wire(m, ApiProtocol.anthropic)).toList(),
        if (system.trim().isNotEmpty) 'system': system,
        'stream': config.streaming,
        'max_tokens': config.maxOutput,
        if (temperature != null) 'temperature': temperature,
      },
      ApiProtocol.gemini => {
        'contents': history
            .map(
              (m) => {
                'role': m['role'] == 'assistant' ? 'model' : 'user',
                'parts': [
                  {'text': m['content']},
                  if (m['image'] case final image?)
                    {
                      'inlineData': {
                        'mimeType': image.substring(5, image.indexOf(';')),
                        'data': image.substring(image.indexOf(',') + 1),
                      },
                    },
                ],
              },
            )
            .toList(),
        if (system.trim().isNotEmpty)
          'systemInstruction': {
            'parts': [
              {'text': system},
            ],
          },
        'generationConfig': {
          'maxOutputTokens': config.maxOutput,
          if (temperature != null) 'temperature': temperature,
        },
      },
    };
  }

  Stream<ChatEvent> get events async* {
    var complete = false;
    try {
      if (cancelled) return;
      if (_betaHeaders == null) {
        try {
          config.endpoint();
        } on FormatException catch (e) {
          throw ChatFailure(e.message);
        }
      }
      ContextBudgetResult budget;
      try {
        budget = budgetContext(
          history: history,
          system: system,
          contextLimit: config.contextLimit,
          outputTokens: _fixedPath != null
              ? config.maxOutput.clamp(1, 4096)
              : config.maxOutput,
          account: _fixedPath != null,
          serialize: _body,
        );
      } on ContextBudgetException {
        throw const ChatFailure(
          '当前提问、待发图片或角色设定超过模型上下文/请求上限，请减少本轮内容或输出上限后重试。未发送请求，本地记录已保留。',
          code: 'context_budget_exceeded',
        );
      }
      final body = budget.body;
      if (budget.notice != null) yield ChatEvent(notice: budget.notice);
      final headers = _betaHeaders == null
          ? _headers(config, _key)
          : {
              'Content-Type': 'application/json',
              'Accept': config.streaming
                  ? 'text/event-stream'
                  : 'application/json',
              ...await _betaHeaders(body),
            };
      if (cancelled) return;
      final request =
          http.AbortableRequest(
              'POST',
              _betaHeaders == null
                  ? config.endpoint()
                  : Uri.https('skymoni.com', _fixedPath!),
              abortTrigger: _abort.future,
            )
            ..followRedirects = false
            ..headers.addAll(headers)
            ..bodyBytes = utf8.encode(body);
      final response = await _client
          .send(request)
          .timeout(Duration(seconds: config.timeoutSeconds));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final text = await _boundedText(
          response.stream.timeout(Duration(seconds: config.timeoutSeconds)),
        );
        try {
          final raw = jsonDecode(text);
          final failure = _knownFailure(raw);
          if (failure != null) throw failure;
        } on FormatException {
          /* sanitized fallback */
        }
        throw _fixedPath?.startsWith('/api/app-account/') == true
            ? _accountHttpError(response.statusCode)
            : _httpError(response.statusCode);
      }
      final stream = response.stream.timeout(
        Duration(seconds: config.timeoutSeconds),
      );
      if ((response.headers['content-type'] ?? '').contains(
            'application/json',
          ) ||
          !config.streaming) {
        final text = await _boundedText(stream);
        final raw = jsonDecode(text) as Map<String, dynamic>;
        yield _decode(raw, full: true);
        return;
      }
      var data = <String>[];
      var received = 0;
      await for (final line
          in stream.transform(utf8.decoder).transform(const LineSplitter())) {
        if (cancelled) return;
        received += line.length;
        if (received > 16000000)
          throw const ChatFailure('回复超出本次接收上限，已保留收到的内容。');
        if (line.startsWith('data:')) {
          data.add(line.substring(5).trimLeft());
        } else if (line.isEmpty && data.isNotEmpty) {
          final payload = data.join('\n');
          data = [];
          if (payload.trim() == '[DONE]') {
            yield const ChatEvent(done: true);
            return;
          }
          final event = _decode(jsonDecode(payload) as Map<String, dynamic>);
          complete = complete || event.done;
          yield event;
        }
      }
      if (data.isNotEmpty) {
        final payload = data.join('\n');
        if (payload.trim() == '[DONE]') {
          complete = true;
        } else {
          final event = _decode(jsonDecode(payload) as Map<String, dynamic>);
          complete = complete || event.done;
          yield event;
        }
      }
      if (!complete && !cancelled)
        throw const ChatFailure('连接提前结束，已保留收到的内容。请重试。');
    } on ChatFailure {
      if (!cancelled) rethrow;
    } on TimeoutException {
      if (!cancelled && !complete)
        throw const ChatFailure('等待回复超时，已保留收到的内容。请检查网络后重试。');
    } on FormatException {
      if (!cancelled) throw const ChatFailure('服务返回了无法识别的数据，请检查接口协议。');
    } catch (_) {
      if (!cancelled) throw const ChatFailure('连接失败，请检查网络和 API 地址后重试。');
    } finally {
      _client.close();
    }
  }

  Future<String> _boundedText(Stream<List<int>> stream) async {
    final bytes = <int>[];
    await for (final part in stream) {
      if (cancelled) return '{}';
      if (bytes.length + part.length > 16000000)
        throw const ChatFailure('服务回复过大，请减少输出长度。');
      bytes.addAll(part);
    }
    return utf8.decode(bytes);
  }

  ChatEvent _decode(Map<String, dynamic> raw, {bool full = false}) {
    final known = _knownFailure(raw);
    if (known != null) throw known;
    if (raw['error'] != null ||
        raw['type'] == 'error' ||
        raw['type'] == 'response.failed') {
      throw const ChatFailure('模型服务返回错误，请检查账户、模型和接口配置。');
    }
    switch (config.protocol) {
      case ApiProtocol.chat:
        final choices = raw['choices'] as List? ?? [];
        final first = choices.isEmpty
            ? <String, dynamic>{}
            : choices.first as Map;
        final content =
            (full ? first['message'] : first['delta']) as Map? ?? {};
        if (first['finish_reason'] == 'content_filter')
          throw const ChatFailure('服务未返回可显示内容，请调整问题后重试。');
        return ChatEvent(
          text: _text(content['content']),
          thinking: _text(content['reasoning_content'] ?? content['reasoning']),
          usage: _usage(raw['usage']),
          done: full || first['finish_reason'] != null,
          limited: first['finish_reason'] == 'length',
        );
      case ApiProtocol.responses:
        if (full ||
            raw['type'] == 'response.completed' ||
            raw['type'] == 'response.incomplete') {
          final r = (raw['response'] as Map?) ?? raw;
          final output = r['output'] as List? ?? [];
          final text = full
              ? output
                    .whereType<Map>()
                    .expand(
                      (m) => (m['content'] as List? ?? []).whereType<Map>(),
                    )
                    .where((m) => m['type'] == 'output_text')
                    .map((m) => m['text'] ?? '')
                    .join()
              : '';
          return ChatEvent(
            text: text,
            usage: _usage(r['usage']),
            done: true,
            limited: r['status'] == 'incomplete',
          );
        }
        return ChatEvent(
          text: raw['type'] == 'response.output_text.delta'
              ? raw['delta'] as String? ?? ''
              : '',
          thinking: raw['type'] == 'response.reasoning_summary_text.delta'
              ? raw['delta'] as String? ?? ''
              : '',
        );
      case ApiProtocol.anthropic:
        final u = raw['usage'] ?? (raw['message'] as Map?)?['usage'];
        final usage = u is Map
            ? ApiUsage(
                input: _int(u['input_tokens']) == null
                    ? null
                    : (_int(u['input_tokens'])! +
                          (_int(u['cache_read_input_tokens']) ?? 0) +
                          (_int(u['cache_creation_input_tokens']) ?? 0)),
                output: _int(u['output_tokens']),
                cached: _int(u['cache_read_input_tokens']),
              )
            : null;
        if (full) {
          final blocks = (raw['content'] as List? ?? []).whereType<Map>();
          return ChatEvent(
            text: blocks
                .where((b) => b['type'] == 'text')
                .map((b) => b['text'] ?? '')
                .join(),
            thinking: blocks
                .where((b) => b['type'] == 'thinking')
                .map((b) => b['thinking'] ?? '')
                .join(),
            usage: usage,
            done: true,
            limited: raw['stop_reason'] == 'max_tokens',
          );
        }
        final delta = raw['delta'] as Map? ?? {};
        final block = raw['content_block'] as Map? ?? {};
        return ChatEvent(
          text: delta['text'] as String? ?? block['text'] as String? ?? '',
          thinking:
              delta['thinking'] as String? ??
              block['thinking'] as String? ??
              '',
          usage: usage,
          done: raw['type'] == 'message_stop',
          limited: delta['stop_reason'] == 'max_tokens',
        );
      case ApiProtocol.gemini:
        final candidates = raw['candidates'] as List? ?? [];
        if (candidates.isEmpty && raw['promptFeedback'] != null)
          throw const ChatFailure('服务没有生成回复，请调整问题后重试。');
        final candidate = candidates.isEmpty
            ? <String, dynamic>{}
            : candidates.first as Map;
        final parts = ((candidate['content'] as Map?)?['parts'] as List? ?? [])
            .whereType<Map>();
        final u = raw['usageMetadata'] as Map?;
        final finish = candidate['finishReason'];
        if (finish != null && !['STOP', 'MAX_TOKENS'].contains(finish))
          throw const ChatFailure('服务停止了本次回复，请调整问题后重试。');
        return ChatEvent(
          text: parts
              .where((p) => p['thought'] != true)
              .map((p) => p['text'] ?? '')
              .join(),
          thinking: parts
              .where((p) => p['thought'] == true)
              .map((p) => p['text'] ?? '')
              .join(),
          usage: u == null
              ? null
              : ApiUsage(
                  input: _int(u['promptTokenCount']),
                  output: _int(u['candidatesTokenCount']),
                  cached: _int(u['cachedContentTokenCount']),
                ),
          done: full || finish != null,
          limited: finish == 'MAX_TOKENS',
        );
    }
  }
}

int? _int(dynamic value) => value is int && value >= 0 ? value : null;
String _text(dynamic value) => value is String
    ? value
    : value is List
    ? value
          .whereType<Map>()
          .map((p) => p['text'] is String ? p['text'] : '')
          .join()
    : '';
ApiUsage? _usage(dynamic raw) => raw is Map
    ? ApiUsage(
        input: _int(raw['prompt_tokens'] ?? raw['input_tokens']),
        output: _int(raw['completion_tokens'] ?? raw['output_tokens']),
        cached: _int(
          (raw['prompt_tokens_details'] as Map?)?['cached_tokens'] ??
              (raw['input_tokens_details'] as Map?)?['cached_tokens'] ??
              raw['prompt_cache_hit_tokens'],
        ),
      )
    : null;

ChatFailure? _knownFailure(dynamic raw) {
  if (raw is! Map) return null;
  final code = raw['code'] ?? raw['type'];
  if (code == 'model_not_available')
    return const ChatFailure(
      '模型未开放或已下架，请更新模型列表并切换到当前可用模型',
      code: 'model_not_available',
    );
  if (code == 'APP_SESSION_INVALID')
    return const ChatFailure('账号登录已过期，请重新登录。', code: 'APP_SESSION_INVALID');
  if ([
    'BETA_NOT_APPROVED',
    'BETA_QUOTA_EXHAUSTED',
    'BETA_CHANNEL_DISABLED',
  ].contains(code)) {
    return ChatFailure(switch (code) {
      'BETA_NOT_APPROVED' => '内测尚未批准或已暂停，请查看内测计划。',
      'BETA_QUOTA_EXHAUSTED' => '内测额度已用完，请等待管理员发放。',
      _ => '内测服务暂未开放，请稍后重试。',
    }, code: code as String);
  }
  for (final key in ['error', 'response']) {
    final nested = _knownFailure(raw[key]);
    if (nested != null) return nested;
  }
  return null;
}

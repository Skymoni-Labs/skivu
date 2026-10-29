import 'dart:convert';
import 'package:http/http.dart' as http;
import 'chat_api.dart';
import 'model_connection.dart';
import 'model_settings.dart';
import 'relay_account.dart';

/// A session-scoped selection catalog. Only labels and opaque selection IDs
/// cross the broker; API keys and endpoint configurations stay in the host.
class LocalRuntimeModels {
  LocalRuntimeModels({
    required this.account,
    required this.custom,
    required this.useAccount,
  }) {
    _scope = scope;
    if (account.signedIn) {
      for (final model in account.models) {
        _account['account:$model'] = model;
      }
    }
    for (final model in custom.connections) {
      _custom['custom:${model.id}'] = model;
    }
  }
  final RelayAccount account;
  final ModelSettings custom;
  final bool useAccount;
  late final String _scope;
  final _account = <String, String>{};
  final _custom = <String, ModelConnection>{};
  String get scope => jsonEncode({
    'account': [
      account.authorizationRevision,
      account.signedIn,
      account.user?['id'],
      account.expiresAt?.millisecondsSinceEpoch,
      account.funding,
    ],
    'custom': custom.connections.map((c) => c.toJson()).toList(),
  });
  bool get valid => scope == _scope;
  void check() {
    if (!valid) throw const ChatFailure('账号或模型配置已变化，请重新打开 DSH 以同步授权。');
  }

  List<Map<String, Object>> list() {
    check();
    return [
      for (final entry in _account.entries)
        if (account.models.contains(entry.value))
          {
            'id': entry.key,
            'name': entry.value,
            'provider': 'Skymoni',
            'supportsTools': account.protocols[entry.value] == 'chat',
          },
      for (final entry in _custom.entries)
        {
          'id': entry.key,
          'name': entry.value.name.isEmpty
              ? entry.value.model
              : '${entry.value.name} · ${entry.value.model}',
          'provider': '自定义',
          'supportsTools': entry.value.protocol == ApiProtocol.chat,
        },
    ].take(512).toList();
  }

  Future<AgentChatSession> open(String? id) async {
    check();
    if (id == null) {
      if (useAccount) return account.startAgentChat();
      id = 'custom:${custom.activeId}';
    }
    final model = _account[id];
    if (model != null) return account.startAgentChat(model: model);
    final config = _custom[id];
    if (config == null)
      throw const ChatFailure(
        '模型未开放或已移除，请同步模型列表并重新选择。',
        code: 'model_not_available',
      );
    if (config.protocol != ApiProtocol.chat)
      throw const ChatFailure('此自定义连接暂不支持编程工具调用，请使用 OpenAI 兼容 chat 接口。');
    final key = await custom.keyFor(config.id);
    check();
    config.endpoint();
    return AgentChatSession.custom(http.Client(), config, key);
  }
}

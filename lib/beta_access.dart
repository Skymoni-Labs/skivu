import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'chat_api.dart';
import 'model_connection.dart';

class BetaKeystore {
  static const _channel = MethodChannel('skivu/beta_keystore');
  bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  Future<Map<String, dynamic>> attest(String challenge) async =>
      Map<String, dynamic>.from(
        await _channel.invokeMethod<Map>('attest', {'challenge': challenge}) ??
            {},
      );
  Future<bool> exists(String alias) async =>
      await _channel.invokeMethod<bool>('exists', {'alias': alias}) ?? false;
  Future<void> delete(String alias) =>
      _channel.invokeMethod('delete', {'alias': alias});
  Future<String> sign(Map<String, dynamic> fields) async =>
      await _channel.invokeMethod<String>('sign', fields) ??
      (throw const ChatFailure('设备签名未完成，请重新配对。'));
}

class BetaAccess extends ChangeNotifier {
  BetaAccess({
    BetaKeystore? keystore,
    FlutterSecureStorage? secure,
    http.Client Function()? clientFactory,
  }) : keystore = keystore ?? BetaKeystore(),
       _secure = secure ?? const FlutterSecureStorage(),
       _clientFactory = clientFactory ?? http.Client.new;
  final BetaKeystore keystore;
  final FlutterSecureStorage _secure;
  final http.Client Function() _clientFactory;
  static const _storageKey = 'skivu.beta.device.v1';
  String? _token, _alias;
  bool paired = false, busy = false;
  String? pairCode, activeModel, error;
  DateTime? pairExpires;
  List<String> models = [];
  Map<String, String> modelProtocols = {};
  Map<String, dynamic>? account;
  num? quotaPerUnit;
  bool get supported => keystore.supported;
  bool get enrolled => _token != null && _alias != null;
  bool get canChat =>
      supported &&
      enrolled &&
      paired &&
      account?['status'] == 'approved' &&
      models.contains(activeModel);
  ModelConnection? get connection => !canChat
      ? null
      : ModelConnection(
          id: 'skymoni-beta',
          name: 'Skymoni 内测',
          provider: 'Skymoni 内测',
          protocol: modelProtocols[activeModel] == 'responses'
              ? ApiProtocol.responses
              : ApiProtocol.chat,
          address: 'https://skymoni.com${_chatPath}',
          model: activeModel!,
          maxOutput: 2048,
        );
  String get _chatPath => modelProtocols[activeModel] == 'responses'
      ? '/api/app-beta/responses'
      : '/api/app-beta/chat/completions';

  Future<void> restore() async {
    if (!supported) return;
    try {
      final text = await _secure.read(key: _storageKey);
      if (text == null) return;
      final raw = jsonDecode(text) as Map<String, dynamic>;
      final alias = raw['alias'] as String;
      if (!await keystore.exists(alias))
        throw const ChatFailure('设备密钥不可用，请重新配对内测。');
      _alias = alias;
      _token = raw['token'] as String;
      activeModel = raw['model'] as String?;
    } catch (_) {
      error = '内测设备凭据暂不可用，请重新配对。';
    }
    notifyListeners();
  }

  Future<Map<String, String>> signedHeaders(
    String method,
    String path,
    String body,
  ) async {
    if (!supported ||
        !enrolled ||
        ![
          '/api/app-beta/device',
          '/api/app-beta/chat/completions',
          '/api/app-beta/responses',
        ].contains(path))
      throw const ChatFailure('请先完成内测设备配对。');
    final token = _token!;
    final random = Random.secure();
    final nonce = base64UrlEncode(
      List<int>.generate(24, (_) => random.nextInt(256)),
    ).replaceAll('=', '');
    final time = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    final proof = await keystore.sign({
      'alias': _alias,
      'method': method,
      'path': path,
      'time': time,
      'nonce': nonce,
      'bodyHash': sha256.convert(utf8.encode(body)).toString(),
      'tokenHash': sha256.convert(utf8.encode(token)).toString(),
    });
    return {
      'Authorization': 'BetaDevice $token',
      'X-Beta-Time': '$time',
      'X-Beta-Nonce': nonce,
      'X-Beta-Proof': proof,
    };
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
    bool authenticated = false,
  }) async {
    final client = _clientFactory();
    try {
      final text = body == null ? '' : jsonEncode(body);
      final request = http.Request(method, Uri.https('skymoni.com', path))
        ..followRedirects = false
        ..headers.addAll({
          'Content-Type': 'application/json',
          if (authenticated) ...await signedHeaders(method, path, text),
        })
        ..bodyBytes = utf8.encode(text);
      final response = await http.Response.fromStream(
        await client.send(request).timeout(const Duration(seconds: 20)),
      ).timeout(const Duration(seconds: 20));
      if (response.statusCode == 503 || response.statusCode == 404)
        throw const ChatFailure('内测服务尚未开放，请稍后再试。');
      if (response.statusCode == 401 || response.statusCode == 403)
        throw const ChatFailure('内测设备验证未通过。请确认使用正式签名版本、设备已获准且系统时间正确。');
      if (response.statusCode < 200 || response.statusCode >= 300)
        throw const ChatFailure('内测请求未完成，请稍后重试。');
      final raw =
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      if (raw['success'] != true || raw['data'] is! Map)
        throw const ChatFailure('内测服务暂不可用，请稍后重试。');
      return Map<String, dynamic>.from(raw['data']);
    } on ChatFailure {
      rethrow;
    } catch (_) {
      throw const ChatFailure('无法连接内测服务，请检查网络后重试。');
    } finally {
      client.close();
    }
  }

  Future<void> enroll() async {
    if (busy || !supported) return;
    busy = true;
    error = null;
    notifyListeners();
    String? generatedAlias;
    try {
      final challenge = await _request('POST', '/api/app-beta/challenge');
      final attestation = await keystore.attest(
        challenge['challenge'] as String,
      );
      generatedAlias = attestation['alias'] as String;
      final enrolled = await _request(
        'POST',
        '/api/app-beta/enroll',
        body: {
          'challenge_id': challenge['id'],
          'chain': attestation['chain'],
          'label': attestation['label'],
        },
      );
      final token = enrolled['device_token'] as String;
      final code = enrolled['pair_code'] as String;
      if (!RegExp(r'^[A-Fa-f0-9]{16}$').hasMatch(code) || token.isEmpty)
        throw const ChatFailure('内测配对信息无效，请重新尝试。');
      await _secure.write(
        key: _storageKey,
        value: jsonEncode({'alias': generatedAlias, 'token': token}),
      );
      final previousAlias = _alias;
      _alias = generatedAlias;
      _token = token;
      generatedAlias = null;
      pairCode = code;
      pairExpires = DateTime.fromMillisecondsSinceEpoch(
        (enrolled['pair_expires'] as num).toInt() * 1000,
      );
      paired = false;
      account = null;
      models = [];
      modelProtocols = {};
      activeModel = null;
      if (previousAlias != null) {
        try {
          await keystore.delete(previousAlias);
        } catch (_) {}
      }
    } catch (e) {
      error = e is ChatFailure ? e.message : '设备硬件证明未完成，当前版本或设备可能暂不符合内测条件。';
    } finally {
      if (generatedAlias != null) {
        try {
          await keystore.delete(generatedAlias);
        } catch (_) {}
      }
      busy = false;
      notifyListeners();
    }
  }

  Future<void> refresh() async {
    if (busy || !enrolled) return;
    busy = true;
    error = null;
    notifyListeners();
    try {
      final raw = await _request(
        'GET',
        '/api/app-beta/device',
        authenticated: true,
      );
      paired = raw['paired'] == true;
      account = paired && raw['account'] is Map
          ? Map<String, dynamic>.from(raw['account'])
          : null;
      final protocols = raw['model_protocols'];
      modelProtocols = paired && protocols is Map
          ? {
              for (final entry in protocols.entries)
                if (entry.key is String && entry.value is String)
                  entry.key as String: entry.value as String,
            }
          : {};
      models = paired
          ? (raw['models'] as List? ?? []).whereType<String>().toList()
          : [];
      models.removeWhere(
        (model) =>
            modelProtocols.containsKey(model) &&
            !['chat', 'responses'].contains(modelProtocols[model]),
      );
      quotaPerUnit = raw['quota_per_unit'] as num?;
      if (!models.contains(activeModel)) activeModel = models.firstOrNull;
      if (paired) {
        pairCode = null;
        pairExpires = null;
      }
    } catch (e) {
      error = e is ChatFailure ? e.message : '内测状态更新失败，请稍后重试。';
      paired = false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> selectModel(String model) async {
    if (!models.contains(model) || !enrolled) return;
    await _secure.write(
      key: _storageKey,
      value: jsonEncode({'alias': _alias, 'token': _token, 'model': model}),
    );
    activeModel = model;
    notifyListeners();
  }

  ChatSession startChat(
    List<Map<String, String>> history,
    String prompt, {
    bool? streaming,
    ModelConnection? requestConfig,
  }) {
    final config =
        requestConfig ??
        (streaming == null ? connection : connection?.withStreaming(streaming));
    if (config == null) throw const ChatFailure('内测尚未配对或暂无可用模型，请先检查内测状态。');
    final path = _chatPath;
    return ChatSession.beta(
      _clientFactory(),
      config,
      history,
      prompt,
      (body) => signedHeaders('POST', path, body),
    );
  }
}

final betaAccess = BetaAccess();

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'app_platform.dart';
import 'chat_api.dart';
import 'model_connection.dart';

class RelayAccount extends ChangeNotifier {
  RelayAccount({
    AppPlatform? platform,
    FlutterSecureStorage? secure,
    http.Client Function()? clientFactory,
  }) : platform = platform ?? AppPlatform(),
       _secure = secure ?? const FlutterSecureStorage(),
       _clients = clientFactory ?? http.Client.new;
  final AppPlatform platform;
  final FlutterSecureStorage _secure;
  final http.Client Function() _clients;
  static const _storageKey = 'skivu.relay.account.v1';
  String? _token, _deviceCode, _verifier;
  int _generation = 0;
  bool busy = false;
  String? error, userCode, verificationUrl, activeModel;
  DateTime? expiresAt, authorizationExpires;
  int pollInterval = 5;
  Map<String, dynamic>? user, wallet, session;
  List<Map<String, dynamic>> subscriptions = [];
  List<String> models = [];
  Map<String, String> protocols = {};
  num? quotaPerUnit;
  String currency = 'USD', billingPreference = '';
  bool get supported => platform.supported;
  bool get signedIn =>
      _token != null && expiresAt?.isAfter(DateTime.now()) == true;
  bool get authorizing => _deviceCode != null && _verifier != null;
  bool get canChat => signedIn && user != null && models.contains(activeModel);

  ModelConnection? get connection => !canChat
      ? null
      : ModelConnection(
          id: 'skymoni-account',
          name: 'Skymoni 账号',
          provider: 'Skymoni',
          protocol: protocols[activeModel] == 'responses'
              ? ApiProtocol.responses
              : ApiProtocol.chat,
          address:
              'https://skymoni.com/api/app-account/${protocols[activeModel] == 'responses' ? 'responses' : 'chat/completions'}',
          model: activeModel!,
          maxOutput: 2048,
        );

  Future<void> _persist() => _secure.write(
    key: _storageKey,
    value: jsonEncode({
      'token': _token,
      'expires': expiresAt?.millisecondsSinceEpoch,
      'model': activeModel,
      if (authorizing)
        'pending': {
          'device': _deviceCode,
          'verifier': _verifier,
          'code': userCode,
          'url': verificationUrl,
          'expires': authorizationExpires?.millisecondsSinceEpoch,
          'interval': pollInterval,
        },
    }),
  );

  Future<void> restore() async {
    if (!supported) return;
    try {
      final stored = await _secure.read(key: _storageKey);
      if (stored == null) return;
      final raw = jsonDecode(stored) as Map;
      final deadline = raw['expires'] as int?;
      if (deadline != null &&
          deadline > DateTime.now().millisecondsSinceEpoch) {
        _token = raw['token'] as String?;
        expiresAt = DateTime.fromMillisecondsSinceEpoch(deadline);
        activeModel = raw['model'] as String?;
      }
      final pending = raw['pending'];
      if (pending is Map &&
          (pending['expires'] as int? ?? 0) >
              DateTime.now().millisecondsSinceEpoch) {
        _deviceCode = pending['device'] as String;
        _verifier = pending['verifier'] as String;
        userCode = pending['code'] as String;
        verificationUrl = _website(pending['url'] as String);
        authorizationExpires = DateTime.fromMillisecondsSinceEpoch(
          pending['expires'] as int,
        );
        pollInterval = (pending['interval'] as int? ?? 5).clamp(5, 60);
      }
      if (signedIn) await refresh();
    } catch (_) {
      error = '账号连接暂不可用，请重新登录。';
    }
    notifyListeners();
  }

  String _website(String text) {
    final uri = Uri.parse(text);
    if (uri.scheme != 'https' ||
        uri.host != 'skymoni.com' ||
        uri.userInfo.isNotEmpty ||
        (uri.hasPort && uri.port != 443))
      throw const ChatFailure('授权地址无效。');
    return text;
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
    String? token,
  }) async {
    final client = _clients();
    try {
      final request =
          http.Request(
              method,
              Uri.https('skymoni.com', '/api/app-account/$path'),
            )
            ..followRedirects = false
            ..headers['Content-Type'] = 'application/json';
      if (token != null) request.headers['Authorization'] = 'AppAccount $token';
      if (body != null) request.bodyBytes = utf8.encode(jsonEncode(body));
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 20));
      final bytes = <int>[];
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 20),
      )) {
        if (bytes.length + chunk.length > 1048576)
          throw const ChatFailure('账号服务返回异常。');
        bytes.addAll(chunk);
      }
      final raw = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      if (response.statusCode == 401 && raw['code'] == 'APP_SESSION_INVALID')
        throw const ChatFailure('账号登录已过期，请重新登录。', code: 'APP_SESSION_INVALID');
      if (response.statusCode < 200 ||
          response.statusCode >= 300 ||
          raw['success'] != true) {
        final code = raw['code'] as String?;
        throw ChatFailure(switch (code) {
          'AUTHORIZATION_PENDING' => '等待网页授权。',
          'ACCESS_DENIED' => '此次授权已取消。',
          'EXPIRED_TOKEN' => '授权已过期，请重新登录。',
          'SLOW_DOWN' => '正在等待授权，请稍候。',
          'AUTH_SESSION_LIMIT' ||
          'AUTH_ISSUANCE_LIMIT' => '登录会话已达上限。请在中转站管理现有会话后重试。',
          _ =>
            response.statusCode == 503 || response.statusCode == 404
                ? '账号服务暂未开放，请稍后再试。'
                : '账号操作未完成，请稍后重试。',
        }, code: code);
      }
      return Map<String, dynamic>.from(raw['data'] as Map? ?? {});
    } on ChatFailure {
      rethrow;
    } catch (_) {
      throw const ChatFailure('无法连接账号服务，请检查网络后重试。');
    } finally {
      client.close();
    }
  }

  Future<void> beginAuthorization() async {
    if (busy || !supported || signedIn) return;
    busy = true;
    error = null;
    final generation = ++_generation;
    notifyListeners();
    try {
      final random = Random.secure();
      final verifier = base64UrlEncode(
        List.generate(32, (_) => random.nextInt(256)),
      ).replaceAll('=', '');
      final challenge = base64UrlEncode(
        sha256.convert(ascii.encode(verifier)).bytes,
      ).replaceAll('=', '');
      final raw = await _request(
        'POST',
        'authorize',
        body: {'code_challenge': challenge, 'device_name': 'Skivu Android'},
      );
      if (generation != _generation) return;
      final deviceCode = raw['device_code'] as String;
      final code = raw['user_code'] as String;
      final url = _website(raw['verification_uri_complete'] as String);
      if (deviceCode.isEmpty ||
          deviceCode.length > 1024 ||
          code.isEmpty ||
          code.length > 64)
        throw const ChatFailure('账号授权信息无效。');
      _deviceCode = deviceCode;
      _verifier = verifier;
      userCode = code;
      verificationUrl = url;
      final seconds = (raw['expires_in'] as num).toInt().clamp(1, 600);
      authorizationExpires = DateTime.now().add(Duration(seconds: seconds));
      pollInterval = (raw['interval'] as num? ?? 5).toInt().clamp(5, 60);
      await _persist();
      await platform.openWebsite(verificationUrl!);
    } catch (e) {
      error = e is ChatFailure ? e.message : '登录页面未能打开，请重新尝试。';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> reopenAuthorization() async {
    if (verificationUrl == null) return;
    try {
      await platform.openWebsite(_website(verificationUrl!));
    } catch (_) {
      error = '登录页面未能打开，请重新尝试。';
      notifyListeners();
    }
  }

  Future<void> pollAuthorization() async {
    if (busy || !authorizing) return;
    if (authorizationExpires?.isAfter(DateTime.now()) != true) {
      await cancelAuthorization();
      error = '授权已过期，请重新登录。';
      notifyListeners();
      return;
    }
    busy = true;
    final generation = _generation;
    try {
      final raw = await _request(
        'POST',
        'token',
        body: {'device_code': _deviceCode, 'code_verifier': _verifier},
      );
      final token = raw['access_token'] as String;
      if (generation != _generation) {
        try {
          await _request('DELETE', 'session', token: token);
        } catch (_) {}
        return;
      }
      if (token.isEmpty || raw['token_type'] != 'AppAccount')
        throw const ChatFailure('账号授权信息无效。');
      _token = token;
      expiresAt = DateTime.fromMillisecondsSinceEpoch(
        (raw['expires_at'] as num).toInt() * 1000,
      );
      _clearPending();
      try {
        await _persist();
      } catch (_) {
        _token = null;
        expiresAt = null;
        try {
          await _request('DELETE', 'session', token: token);
        } catch (_) {}
        throw const ChatFailure('无法安全保存登录，请重试。');
      }
      error = null;
    } on ChatFailure catch (e) {
      if (generation != _generation) return;
      if (e.code == 'SLOW_DOWN')
        pollInterval = (pollInterval + 5).clamp(5, 60);
      else if (e.code != 'AUTHORIZATION_PENDING') {
        error = e.message;
        if ([
          'EXPIRED_TOKEN',
          'ACCESS_DENIED',
          'AUTH_SESSION_LIMIT',
          'AUTH_ISSUANCE_LIMIT',
        ].contains(e.code)) {
          _clearPending();
          await _persist();
        }
      }
    } catch (_) {
      error = '授权状态更新失败，请重新尝试。';
    } finally {
      busy = false;
      notifyListeners();
    }
    if (signedIn) await refresh();
  }

  void _clearPending() {
    _deviceCode = null;
    _verifier = null;
    userCode = null;
    verificationUrl = null;
    authorizationExpires = null;
  }

  Future<void> cancelAuthorization() async {
    ++_generation;
    _clearPending();
    await _persist();
    notifyListeners();
  }

  Future<void> refresh() async {
    if (busy || !signedIn) return;
    busy = true;
    error = null;
    final generation = _generation;
    notifyListeners();
    try {
      final me = await _request('GET', 'me', token: _token);
      final catalog = await _request('GET', 'models', token: _token);
      if (generation != _generation) return;
      user = Map<String, dynamic>.from(me['user'] as Map);
      wallet = Map<String, dynamic>.from(me['wallet'] as Map);
      session = Map<String, dynamic>.from(me['session'] as Map);
      subscriptions = (me['subscriptions'] as List? ?? [])
          .whereType<Map>()
          .map((s) => Map<String, dynamic>.from(s))
          .toList();
      quotaPerUnit = me['quota_per_unit'] as num?;
      currency = me['currency'] as String? ?? 'USD';
      billingPreference = me['billing_preference'] as String? ?? '';
      protocols = {
        for (final e in (catalog['model_protocols'] as Map? ?? {}).entries)
          if (e.key is String && e.value is String)
            e.key as String: e.value as String,
      };
      models = (catalog['models'] as List? ?? [])
          .whereType<String>()
          .where((id) => ['chat', 'responses'].contains(protocols[id]))
          .toList();
      if (!models.contains(activeModel)) activeModel = models.firstOrNull;
      await _persist();
    } on ChatFailure catch (e) {
      if (generation != _generation) return;
      if (e.code == 'APP_SESSION_INVALID') await invalidate();
      error = e.message;
    } catch (_) {
      error = '账号信息暂未同步，请刷新重试。';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> selectModel(String model) async {
    if (!models.contains(model)) return;
    final previous = activeModel;
    activeModel = model;
    try {
      await _persist();
    } catch (_) {
      activeModel = previous;
      rethrow;
    }
    notifyListeners();
  }

  Future<void> invalidate() async {
    ++_generation;
    _token = null;
    expiresAt = null;
    user = null;
    wallet = null;
    session = null;
    activeModel = null;
    models = [];
    protocols = {};
    subscriptions = [];
    _clearPending();
    await _secure.delete(key: _storageKey);
    notifyListeners();
  }

  Future<void> logout() async {
    if (busy) return;
    busy = true;
    notifyListeners();
    try {
      if (_token != null) {
        try {
          await _request('DELETE', 'session', token: _token);
        } on ChatFailure catch (e) {
          if (e.code != 'APP_SESSION_INVALID') rethrow;
        }
      }
      await invalidate();
      error = null;
    } catch (e) {
      error = e is ChatFailure ? e.message : '退出未完成，请重试。';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  ChatSession startChat(List<Map<String, String>> history, String prompt) {
    final config = connection;
    if (config == null) throw const ChatFailure('请先登录中转站并同步模型。');
    return ChatSession.account(_clients(), config, history, prompt, _token!);
  }
}

final relayAccount = RelayAccount();

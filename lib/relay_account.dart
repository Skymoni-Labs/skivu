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
  bool loggingOut = false;
  String? error, userCode, verificationUrl, activeModel;
  DateTime? expiresAt, authorizationExpires;
  int pollInterval = 5;
  Map<String, dynamic>? user, wallet, session;
  List<Map<String, dynamic>> subscriptions = [];
  List<String> models = [];
  Map<String, String> protocols = {};
  num? quotaPerUnit;
  String currency = 'USD', billingPreference = '';
  String funding = 'relay';
  int maxOutput = 2048;
  bool streaming = true;
  Map<String, dynamic>? betaStatus;
  Map<String, dynamic>? loginOptions;
  String? verificationFlow;
  List<String> verificationMethods = [];
  bool needsBrowser = false;
  bool get canBetaChat => signedIn && betaStatus?['can_chat'] == true;
  Map get betaAccount =>
      betaStatus?['account'] is Map ? betaStatus!['account'] as Map : {};
  String get betaMessage => switch (betaStatus?['blocked_reason']) {
    'NOT_APPROVED' => switch (betaAccount['status']) {
      'pending' => '申请已提交，正在等待管理员审核。',
      'rejected' => '申请未通过，可在网页查看审核结果。',
      'suspended' => '内测资格已暂停，请联系管理员。',
      _ => '尚未开通内测计划，可前往网页申请。',
    },
    'CHANNEL_DISABLED' => '内测资格已开通，服务暂未开放。',
    'QUOTA_EXHAUSTED' => '内测额度已用完，请等待管理员发放。',
    _ => canBetaChat ? '内测已开通，额度由管理员发放。' : '内测状态尚未同步，请刷新。',
  };

  bool get supported => platform.supported;
  bool get signedIn =>
      _token != null && expiresAt?.isAfter(DateTime.now()) == true;
  bool get authorizing => _deviceCode != null && _verifier != null;
  bool get canChat =>
      signedIn &&
      user != null &&
      models.contains(activeModel) &&
      (funding != 'beta' || canBetaChat);

  ModelConnection? get connection => !canChat
      ? null
      : ModelConnection(
          id: 'skymoni-account',
          name: funding == 'beta' ? 'Skymoni 内测' : 'Skymoni 账号',
          provider: funding == 'beta' ? 'Skymoni 内测' : 'Skymoni',
          protocol: protocols[activeModel] == 'responses'
              ? ApiProtocol.responses
              : ApiProtocol.chat,
          address:
              'https://skymoni.com/api/app-account/${protocols[activeModel] == 'responses' ? 'responses' : 'chat/completions'}',
          model: activeModel!,
          maxOutput: maxOutput,
          streaming: streaming,
        );

  Future<void> _persist() => _secure.write(
    key: _storageKey,
    value: jsonEncode({
      'token': _token,
      'expires': expiresAt?.millisecondsSinceEpoch,
      'model': activeModel,
      'funding': funding,
      'maxOutput': maxOutput,
      'streaming': streaming,
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
      funding = raw['funding'] == 'beta' ? 'beta' : 'relay';
      maxOutput = (raw['maxOutput'] as int? ?? 2048).clamp(128, 4096);
      streaming = raw['streaming'] != false;
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
    Map<String, String>? query,
  }) async {
    final client = _clients();
    try {
      final request =
          http.Request(
              method,
              Uri.https('skymoni.com', '/api/app-account/$path', query),
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
          'INVALID_CREDENTIALS' || 'LOGIN_FAILED' => '账号或密码不正确。',
          'CAPTCHA_REQUIRED' => '此账号需要网页安全验证。',
          'MFA_INVALID' || 'VERIFICATION_FAILED' => '验证码不正确或已过期。',
          'RATE_LIMITED' => '尝试过于频繁，请稍后再试。',
          'BETA_NOT_APPROVED' => '内测尚未批准或已暂停。',
          'BETA_QUOTA_EXHAUSTED' => '内测额度已用完，请等待管理员发放。',
          'BETA_CHANNEL_DISABLED' => '内测服务暂未开放，请稍后重试。',
          'AUTHORIZATION_PENDING' => '等待网页授权。',
          'ACCESS_DENIED' => '此次授权已取消。',
          'EXPIRED_TOKEN' => '授权已过期，请重新登录。',
          'SLOW_DOWN' => '正在等待授权，请稍候。',
          'AUTH_SESSION_LIMIT' ||
          'AUTH_ISSUANCE_LIMIT' => '登录会话已达上限。请在中转站管理现有会话后重试。',
          _ =>
            response.statusCode == 503 || response.statusCode == 404
                ? '账号服务暂未开放，请稍后再试。'
                : (raw['message']?.toString().toLowerCase().contains(
                            'password',
                          ) ==
                          true ||
                      raw['message']?.toString().contains('密码') == true)
                ? '账号或密码不正确，请检查后重试。'
                : (raw['message']?.toString().contains('验证') == true
                      ? '账号安全验证未完成，请重试或使用网页登录。'
                      : '账号操作未完成，请稍后重试。'),
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

  Future<void> selectFunding(String value) async {
    if (busy || !['relay', 'beta'].contains(value)) return;
    if (funding != value) {
      models = [];
      protocols = {};
      activeModel = null;
    }
    funding = value;
    await _persist();
    await refresh();
    notifyListeners();
  }

  Future<void> setGeneration(int output, bool stream) async {
    maxOutput = output.clamp(128, 4096);
    streaming = stream;
    await _persist();
    notifyListeners();
  }

  Future<void> signIn(String username, String password) async {
    if (busy || !supported || signedIn) return;
    busy = true;
    error = null;
    needsBrowser = false;
    verificationFlow = null;
    final generation = ++_generation;
    _clearPending();
    notifyListeners();
    try {
      if (username.trim().isEmpty || password.isEmpty)
        throw const ChatFailure('请填写账号和密码。');
      final options = loginOptions = await _request('GET', 'login/options');
      if (options['password_login_enabled'] != true) {
        needsBrowser = true;
        throw const ChatFailure('此站点需要使用网页登录。');
      }
      if ((options['captcha'] as Map?)?['required'] == true) {
        needsBrowser = true;
        throw const ChatFailure('需要额外的网页安全验证，请使用下方验证入口。');
      }
      final encryption = options['encryption'];
      if (encryption is! Map || encryption['enabled'] is! bool)
        throw const ChatFailure('登录安全配置不完整，请稍后重试。');
      final body = <String, dynamic>{
        'username': username.trim(),
        'device_name': 'Skivu Android',
      };
      if (encryption['enabled'] == true) {
        body['password_encrypted'] = await platform.encryptPassword(
          password,
          encryption['public_key'] as String,
        );
        body['encryption_key_id'] = encryption['kid'];
      } else {
        body['password'] = password;
      }
      final data = await _request('POST', 'login', body: body);
      if (generation != _generation) {
        await _discardIssued(data);
        return;
      }
      await _acceptNativeLogin(data);
    } on ChatFailure catch (e) {
      if (generation == _generation) error = e.message;
    } catch (_) {
      if (generation == _generation) error = '登录未完成，请稍后重试。';
    } finally {
      busy = false;
      notifyListeners();
    }
    if (signedIn) await refresh();
  }

  void cancelVerification() {
    if (busy) return;
    ++_generation;
    verificationFlow = null;
    verificationMethods = [];
    needsBrowser = false;
    error = null;
    notifyListeners();
  }

  Future<void> verifySignIn(String code) async {
    if (busy || verificationFlow == null) return;
    busy = true;
    error = null;
    final generation = _generation;
    notifyListeners();
    try {
      final data = await _request(
        'POST',
        'login/verify',
        body: {
          'flow_token': verificationFlow,
          'method': '2fa',
          'code': code.trim(),
        },
      );
      if (generation != _generation) {
        await _discardIssued(data);
        return;
      }
      await _acceptNativeLogin(data);
    } on ChatFailure catch (e) {
      error = e.message;
    } catch (_) {
      error = '验证未完成，请重试。';
    } finally {
      busy = false;
      notifyListeners();
    }
    if (signedIn) await refresh();
  }

  Future<void> _discardIssued(Map data) async {
    if (data['access_token'] is String) {
      try {
        await _request('DELETE', 'session', token: data['access_token']);
      } catch (_) {}
    }
  }

  Future<void> _acceptNativeLogin(Map data) async {
    if (data['require_verification'] == true) {
      verificationFlow = data['flow_token'] as String;
      verificationMethods = (data['methods'] as List? ?? [])
          .whereType<Map>()
          .where((method) => method['available'] == true)
          .map((method) => method['method'])
          .whereType<String>()
          .toList();
      needsBrowser = !verificationMethods.contains('2fa');
      return;
    }
    final token = data['access_token'];
    if (token is! String ||
        token.isEmpty ||
        data['token_type'] != 'AppAccount' ||
        data['expires_at'] is! num)
      throw const ChatFailure('登录响应无效，请重试。');
    _token = token;
    expiresAt = DateTime.fromMillisecondsSinceEpoch(
      (data['expires_at'] as num).toInt() * 1000,
    );
    verificationFlow = null;
    verificationMethods = [];
    needsBrowser = false;
    try {
      await _persist();
    } catch (_) {
      _token = null;
      expiresAt = null;
      await _discardIssued(data);
      throw const ChatFailure('无法安全保存登录，请重试。');
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
      if (generation != _generation) return;
      betaStatus = me['beta'] is Map
          ? Map<String, dynamic>.from(me['beta'])
          : null;
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
      final catalog = await _request(
        'GET',
        'models',
        token: _token,
        query: funding == 'beta' ? {'funding': 'beta'} : null,
      );
      if (generation != _generation) return;
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
      if (generation == _generation) error = '账号信息暂未同步，请刷新重试。';
    } finally {
      if (generation == _generation) busy = false;
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
    // If secure storage fails, keep the account visible so logout can be
    // retried; never present a successful logout with a restorable token.
    await _secure.delete(key: _storageKey);
    _token = null;
    expiresAt = null;
    user = null;
    wallet = null;
    session = null;
    activeModel = null;
    models = [];
    protocols = {};
    subscriptions = [];
    betaStatus = null;
    verificationFlow = null;
    verificationMethods = [];
    funding = 'relay';
    _clearPending();
    notifyListeners();
  }

  Future<void> logout() async {
    if (loggingOut) return;
    final token = _token;
    loggingOut = true;
    busy = true;
    notifyListeners();
    try {
      // Local logout must work offline and invalidate any in-flight refresh.
      await invalidate();
      error = null;
      if (token != null) {
        try {
          await _request(
            'DELETE',
            'session',
            token: token,
          ).timeout(const Duration(seconds: 5));
        } on ChatFailure catch (e) {
          if (e.code != 'APP_SESSION_INVALID') {
            error = '已退出本机。远端授权未能撤销，可在站点的设备管理中撤销。';
          }
        } catch (_) {
          error = '已退出本机。远端授权未能撤销，可在站点的设备管理中撤销。';
        }
      }
    } catch (_) {
      error = '本机登录信息清理未完成，请重试退出。';
    } finally {
      loggingOut = false;
      busy = false;
      notifyListeners();
    }
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
    if (config == null) throw const ChatFailure('请先登录中转站并同步模型。');
    return ChatSession.account(
      _clients(),
      config,
      history,
      prompt,
      _token!,
      funding: funding,
    );
  }
}

final relayAccount = RelayAccount();

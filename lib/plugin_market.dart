import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'ui_plugins.dart';

/// Downloaded data-only presets select a renderer shipped with the host.
/// Packages cannot supply scripts, URLs, prompts, or additional permissions.
const pluginHostVersion = '0.2.20';
const pluginCatalogUrl = 'https://skymoni.com/app-plugins/catalog/index.json';
const pluginCatalogOriginUrl =
    'https://raw.githubusercontent.com/skyjjgw/skivu-plugins/main/catalog/index.json';
const pluginRenderer = 'skivu.social-ui.v1';

int comparePluginVersions(String a, String b) {
  final x = a.split('.').map(int.parse).toList();
  final y = b.split('.').map(int.parse).toList();
  for (var i = 0; i < 3; i++) {
    final n = x[i].compareTo(y[i]);
    if (n != 0) return n;
  }
  return 0;
}

bool _version(Object? v) =>
    v is String &&
    RegExp(r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$').hasMatch(v) &&
    v.length < 30;
String _text(Map data, String key, int max) {
  final v = data[key];
  if (v is! String || v.trim().isEmpty || v.length > max)
    throw const FormatException('插件信息格式不正确。');
  return v;
}

class MarketPlugin {
  MarketPlugin._(this.metadata, this.packageUrl, this.digest, this.bytes);
  final Map<String, dynamic> metadata;
  final Uri? packageUrl;
  final String digest;
  final int bytes;
  String get id => metadata['id'];
  String get name => metadata['name'];
  String get version => metadata['version'];
  String get description => metadata['description'];
  String get minHostVersion => metadata['minHostVersion'];
  ChatUiMode get mode =>
      metadata['mode'] == 'qq' ? ChatUiMode.qq : ChatUiMode.wechat;
  bool get compatible =>
      comparePluginVersions(pluginHostVersion, minHostVersion) >= 0;

  static Map<String, dynamic> preset(Object? value) {
    if (value is! Map ||
        value['schemaVersion'] != 1 ||
        value['kind'] != 'ui-preset' ||
        value['renderer'] != pluginRenderer ||
        value['permissions'] is! List ||
        (value['permissions'] as List).isNotEmpty ||
        !_version(value['version']) ||
        !_version(value['minHostVersion']))
      throw const FormatException('此插件需要其他宿主能力。');
    const keys = {
      'schemaVersion',
      'kind',
      'renderer',
      'id',
      'name',
      'version',
      'author',
      'license',
      'description',
      'repository',
      'mode',
      'minHostVersion',
      'permissions',
    };
    if (value.keys.any((k) => !keys.contains(k)))
      throw const FormatException('插件含有不支持的字段。');
    final data = Map<String, dynamic>.from(value);
    final id = _text(data, 'id', 80), mode = data['mode'];
    if (!((id == 'skivu.wechat' && mode == 'wechat') ||
        (id == 'skivu.qq' && mode == 'qq')))
      throw const FormatException('未知的界面插件。');
    _text(data, 'name', 60);
    _text(data, 'author', 100);
    _text(data, 'description', 300);
    if (data['license'] != 'GPL-3.0-only' ||
        data['repository'] != 'https://github.com/skyjjgw/skivu-plugins')
      throw const FormatException('插件来源或许可不匹配。');
    return data;
  }

  factory MarketPlugin.catalog(Object? value) {
    if (value is! Map || value['package'] is! Map)
      throw const FormatException('目录条目无效。');
    final copy = Map<String, dynamic>.from(value);
    final package = copy.remove('package') as Map;
    final data = preset(copy);
    final url = Uri.tryParse(package['url'] is String ? package['url'] : '');
    final digest = package['sha256'], bytes = package['bytes'];
    if (url == null ||
        url.scheme != 'https' ||
        url.host != 'raw.githubusercontent.com' ||
        url.hasQuery ||
        url.hasFragment ||
        url.userInfo.isNotEmpty ||
        !RegExp(
          r'^/skyjjgw/skivu-plugins/[a-f0-9]{40}/plugins/(wechat|qq)/plugin\.json$',
        ).hasMatch(url.path) ||
        digest is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(digest) ||
        bytes is! int ||
        bytes <= 0 ||
        bytes > 16384)
      throw const FormatException('插件下载信息无效。');
    if (url.pathSegments[4] != data['mode'])
      throw const FormatException('插件下载路径不匹配。');
    return MarketPlugin._(data, url, digest, bytes);
  }

  static List<MarketPlugin> catalogList(String raw) {
    final value = jsonDecode(raw);
    if (value is! Map ||
        value['schemaVersion'] != 2 ||
        value['protocolVersion'] != '1.0' ||
        value['runtimeReady'] != true ||
        value['plugins'] is! List ||
        (value['plugins'] as List).length > 100)
      throw const FormatException('插件目录版本不兼容。');
    final items = (value['plugins'] as List).map(MarketPlugin.catalog).toList();
    if (items.map((v) => v.id).toSet().length != items.length)
      throw const FormatException('插件目录包含重复项目。');
    return items;
  }
}

class PluginMarket extends ChangeNotifier {
  PluginMarket({http.Client? client}) : _client = client ?? http.Client();
  static const storageKey = 'skivu.plugin-market.v1';
  final http.Client _client;
  final Map<String, String> _installed = {};
  List<MarketPlugin> catalog = [];
  String? error, workingId;
  bool loading = false;
  bool _disposed = false;
  MarketPlugin? installedFor(ChatUiMode mode) {
    final raw = _installed[mode == ChatUiMode.qq ? 'skivu.qq' : 'skivu.wechat'];
    if (raw == null) return null;
    try {
      final v = jsonDecode(raw);
      return MarketPlugin._(
        MarketPlugin.preset(v),
        null,
        sha256.convert(utf8.encode(raw)).toString(),
        utf8.encode(raw).length,
      );
    } catch (_) {
      return null;
    }
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> restore() async {
    try {
      final saved = (await SharedPreferences.getInstance()).getString(
        storageKey,
      );
      if (saved != null) {
        final data = jsonDecode(saved) as Map;
        for (final entry in (data['installed'] as Map).entries) {
          if (entry.value is! String) continue;
          final value = MarketPlugin.preset(jsonDecode(entry.value));
          if (value['id'] == entry.key &&
              comparePluginVersions(
                    pluginHostVersion,
                    value['minHostVersion'],
                  ) >=
                  0)
            _installed[entry.key] = entry.value;
        }
        try {
          if (data['catalog'] is String)
            catalog = MarketPlugin.catalogList(data['catalog']);
        } catch (_) {}
      }
    } catch (_) {
      error = '部分插件记录无法读取，可重新安装。聊天记录不受影响。';
    }
    _changed();
  }

  Future<String> _download(Uri uri, int max) async {
    final request = http.Request('GET', uri)..followRedirects = false;
    final response = await _client
        .send(request)
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200 || (response.contentLength ?? 0) > max)
      throw const FormatException('下载失败，请稍后重试。');
    final bytes = <int>[];
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 20),
    )) {
      bytes.addAll(chunk);
      if (bytes.length > max) throw const FormatException('插件文件超过限制。');
    }
    return utf8.decode(bytes);
  }

  Future<String> _mirrored(Uri primary, Uri origin, int max) async {
    try {
      return await _download(primary, max);
    } catch (_) {
      return _download(origin, max);
    }
  }

  Future<void> _save(
    Map<String, String> installed,
    List<MarketPlugin> entries,
  ) async {
    final raw = jsonEncode({
      'installed': installed,
      'catalog': jsonEncode({
        'schemaVersion': 2,
        'protocolVersion': '1.0',
        'runtimeReady': true,
        'plugins': entries
            .map(
              (p) => {
                ...p.metadata,
                'package': {
                  'url': p.packageUrl.toString(),
                  'sha256': p.digest,
                  'bytes': p.bytes,
                },
              },
            )
            .toList(),
      }),
    });
    if (!await (await SharedPreferences.getInstance()).setString(
      storageKey,
      raw,
    ))
      throw const FormatException('插件未能保存，请重试。');
  }

  Future<void> refresh() async {
    if (loading || workingId != null) return;
    loading = true;
    error = null;
    _changed();
    try {
      final entries = MarketPlugin.catalogList(
        await _mirrored(
          Uri.parse(pluginCatalogUrl),
          Uri.parse(pluginCatalogOriginUrl),
          262144,
        ),
      );
      await _save(_installed, entries);
      catalog = entries;
    } catch (e) {
      error = e is FormatException
          ? e.message.toString()
          : '无法连接插件市场，请检查网络后重试。';
    } finally {
      loading = false;
      _changed();
    }
  }

  Future<bool> install(MarketPlugin item) async {
    if (loading || workingId != null) return false;
    workingId = item.id;
    error = null;
    _changed();
    try {
      if (!catalog.any((p) => p.id == item.id && p.digest == item.digest) ||
          !item.compatible)
        throw const FormatException('请刷新目录或更新 App 后安装。');
      final old = installedFor(item.mode);
      if (old != null && comparePluginVersions(item.version, old.version) < 0)
        throw const FormatException('不能安装更旧的插件版本。');
      final raw = await _mirrored(
            Uri.https(
              'skymoni.com',
              '/app-plugins/packages/${item.digest}.json',
            ),
            item.packageUrl!,
            16384,
          ),
          bytes = utf8.encode(raw);
      if (bytes.length != item.bytes ||
          sha256.convert(bytes).toString() != item.digest)
        throw const FormatException('插件完整性校验失败，未安装。');
      final data = MarketPlugin.preset(jsonDecode(raw));
      if (data.entries.any(
        (e) => jsonEncode(e.value) != jsonEncode(item.metadata[e.key]),
      ))
        throw const FormatException('插件内容与目录不一致。');
      final next = {..._installed, item.id: raw};
      await _save(next, catalog);
      _installed
        ..clear()
        ..addAll(next);
      return true;
    } catch (e) {
      error = e is FormatException ? e.message.toString() : '安装失败，请检查网络后重试。';
      return false;
    } finally {
      workingId = null;
      _changed();
    }
  }

  Future<bool> uninstall(ChatUiMode mode, UiPluginSettings settings) async {
    if (loading || workingId != null) return false;
    final item = installedFor(mode);
    if (item == null) return true;
    workingId = item.id;
    error = null;
    _changed();
    try {
      if (settings.mode == mode && !await settings.setEnabled(mode, false))
        throw const FormatException('请先关闭插件后再卸载。');
      final next = {..._installed}..remove(item.id);
      await _save(next, catalog);
      _installed
        ..clear()
        ..addAll(next);
      return true;
    } catch (_) {
      error = '卸载未完成，请重试。聊天记录不受影响。';
      return false;
    } finally {
      workingId = null;
      _changed();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _client.close();
    super.dispose();
  }
}

final pluginMarket = PluginMarket();

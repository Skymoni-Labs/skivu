// SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:crypto/crypto.dart';
import 'open_plugin.dart';
import 'open_plugin_network.dart';

const pluginMethodPermissions = <String, String>{
  'host.info': '',
  'context.get': '',
  'ui.toast': '',
  'ui.openExternal': 'external.open',
  'ui.chatDraft': 'chat.write',
  'ui.roleSettings': '',
  'storage.get': 'storage',
  'storage.set': 'storage',
  'storage.compareAndSet': 'storage',
  'storage.remove': 'storage',
  'storage.keys': 'storage',
  'secrets.get': 'secrets',
  'secrets.set': 'secrets',
  'secrets.remove': 'secrets',
  'fs.read': 'files',
  'fs.write': 'files',
  'fs.list': 'files',
  'fs.remove': 'files',
  'files.pick': 'files',
  'files.save': 'files',
  'https.request': 'network',
  'network.request': 'network',
  'characters.list': 'characters.read',
  'characters.get': 'characters.read',
  'characters.update': 'characters.write',
  'chat.read': 'chat.read',
  'chat.append': 'chat.write',
  'ai.generate': 'ai.generate',
  'prompt.set': 'prompt',
  'clipboard.read': 'clipboard',
  'clipboard.write': 'clipboard',
};

typedef PluginHostCall =
    Future<Object?> Function(String method, Map<String, dynamic> params);
final _queues = <String, Future<void>>{};
Future<T> _serial<T>(String id, Future<T> Function() task) async {
  final previous = _queues[id] ?? Future<void>.value();
  final work = previous.then((_) => task());
  final tail = work.then<void>((_) {}, onError: (Object _, StackTrace __) {});
  _queues[id] = tail;
  try {
    return await work;
  } finally {
    if (identical(_queues[id], tail)) _queues.remove(id);
  }
}

class OpenPluginBridge {
  OpenPluginBridge({
    required this.registry,
    required this.record,
    required this.host,
    PluginNetwork? network,
    FlutterSecureStorage? secure,
    this.guard,
  }) : network = network ?? PluginNetwork(),
       secure = secure ?? const FlutterSecureStorage();
  final OpenPluginRegistry registry;
  final OpenPluginRecord record;
  final PluginHostCall host;
  final PluginNetwork network;
  final FlutterSecureStorage secure;
  final void Function()? guard;
  bool closed = false;
  int pending = 0;
  String get id => record.manifest.id;
  void check() {
    guard?.call();
    if (closed || registry.records[id] != record || !record.authorized)
      throw const PluginApiError('CLOSED', '插件已关闭或需要重新授权。');
  }

  String text(Map p, String key, {int max = 65536, bool empty = false}) {
    final v = p[key];
    if (v is! String ||
        (!empty && v.isEmpty) ||
        v.length > max ||
        v.contains('\u0000'))
      throw PluginApiError('INVALID_ARGUMENT', '$key 格式不正确。');
    return v;
  }

  String key(Map p) {
    final k = text(p, 'key', max: 200);
    if (RegExp(r'[\x00-\x1f]').hasMatch(k))
      throw const PluginApiError('INVALID_ARGUMENT', '键名不正确。');
    return k;
  }

  Future<Map<String, dynamic>> dispatch(Object? raw) async {
    try {
      check();
      if (pending >= 8) throw const PluginApiError('BUSY', '同时运行的宿主请求过多。');
      if (raw is! Map ||
          raw.length != 3 ||
          raw['id'] is! String ||
          !RegExp(r'^[0-9]{1,16}$').hasMatch(raw['id']) ||
          raw['method'] is! String ||
          raw['params'] is! Map)
        throw const PluginApiError('INVALID_ARGUMENT', '宿主请求格式不正确。');
      final method = raw['method'] as String;
      if (!pluginMethodPermissions.containsKey(method))
        throw const PluginApiError('METHOD_NOT_FOUND', '该宿主能力尚未开放。');
      final permission = pluginMethodPermissions[method]!;
      if (permission.isNotEmpty &&
          !record.manifest.permissions.contains(permission))
        throw const PluginApiError('PERMISSION_DENIED', '插件未获准使用此能力。');
      pending++;
      try {
        final result = await _call(
          method,
          Map<String, dynamic>.from(raw['params']),
        );
        check();
        return {'ok': true, 'result': result};
      } finally {
        pending--;
      }
    } on PluginApiError catch (e) {
      return {
        'ok': false,
        'error': {'code': e.code, 'message': e.message},
      };
    } catch (_) {
      return {
        'ok': false,
        'error': {'code': 'OPERATION_FAILED', 'message': '插件的宿主操作未完成。'},
      };
    }
  }

  Future<Object?> _call(String method, Map<String, dynamic> p) async {
    if (method == 'host.info')
      return {
        'apiVersion': openPluginApiVersion,
        'platform': 'android',
        'methods': pluginMethodPermissions.keys.toList(),
        'permissions': record.manifest.permissions,
      };
    if (method.startsWith('storage.'))
      return _serial(id, () async {
        check();
        final value = jsonDecode(await readPluginData(id, 'storage') ?? '{}');
        if (value is! Map)
          throw const PluginApiError('STORAGE_FAILED', '存档读取失败。');
        final data = Map<String, dynamic>.from(value);
        if (method == 'storage.keys') return data.keys.toList();
        final k = key(p);
        if (method == 'storage.get') return data[k];
        if (method == 'storage.compareAndSet' &&
            (!p.containsKey('expected') ||
                !pluginJsonEqual(data[k], p['expected'])))
          throw const PluginApiError('REVISION_CONFLICT', '存档已经变化，请重新读取后再操作。');
        if (method == 'storage.remove')
          data.remove(k);
        else {
          final v = p['value'];
          if (utf8.encode(jsonEncode(v)).length > 10 * 1024 * 1024)
            throw const PluginApiError('LIMIT_EXCEEDED', '单个存档超过 10 MiB。');
          data[k] = v;
        }
        final encoded = jsonEncode(data);
        if (utf8.encode(encoded).length > 64 * 1024 * 1024)
          throw const PluginApiError('LIMIT_EXCEEDED', '插件存档空间已满。');
        check();
        await writePluginData(id, 'storage', encoded);
        registry.storageChanged(id);
        return true;
      });
    if (method.startsWith('secrets.'))
      return _serial(id, () async {
        check();
        final k =
            'skivu.open-plugin.${sha256.convert(utf8.encode(id))}.${base64Url.encode(utf8.encode(key(p)))}';
        if (method == 'secrets.get') return secure.read(key: k);
        if (method == 'secrets.remove')
          await secure.delete(key: k);
        else
          await secure.write(
            key: k,
            value: text(p, 'value', max: 16384, empty: true),
          );
        return true;
      });
    if (method == 'https.request' || method == 'network.request')
      return network.request(
        p,
        record.manifest.domains,
        allowLocal: record.manifest.permissions.contains('network.local'),
      );
    if (method.startsWith('fs.'))
      return _serial(id, () async {
        check();
        if (method == 'fs.list') return listPluginFiles(id);
        final path = text(p, 'path', max: 240);
        if (!pluginRelativePath(path))
          throw const PluginApiError('INVALID_ARGUMENT', '文件路径必须位于本插件工作区。');
        if (method == 'fs.read') {
          final bytes = await readPluginFile(id, path);
          return bytes == null ? null : {'base64': base64Encode(bytes)};
        }
        if (method == 'fs.remove')
          await removePluginFile(id, path);
        else {
          final bytes = base64Decode(
            text(p, 'base64', max: 12 * 1024 * 1024, empty: true),
          );
          await writePluginFile(id, path, Uint8List.fromList(bytes));
        }
        return true;
      });
    return host(method, p);
  }

  void close() {
    closed = true;
    network.close();
  }
}

Future<void> clearOpenPluginSecrets(
  String id, {
  FlutterSecureStorage? secure,
}) async {
  final s = secure ?? const FlutterSecureStorage();
  for (final k
      in (await s.readAll()).keys
          .where(
            (k) => k.startsWith(
              'skivu.open-plugin.${sha256.convert(utf8.encode(id))}.',
            ),
          )
          .toList())
    await s.delete(key: k);
}

Future<void> eraseOpenPluginData(String id) => _serial(id, () async {
  await clearPluginData(id);
  await clearOpenPluginSecrets(id);
});

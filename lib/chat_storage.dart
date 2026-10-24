import 'chat_storage_files.dart';
import 'chat_storage_platform_stub.dart'
    if (dart.library.io) 'chat_storage_platform_io.dart'
    as platform;
import 'package:shared_preferences/shared_preferences.dart';

class ChatStorage {
  ChatStorage({ChatStorageFiles? files})
    : _files = files ?? platform.PlatformChatStorage();
  static const key = 'skivu.conversations.v1';
  final ChatStorageFiles _files;
  void Function(String)? _validator;
  bool _usingFiles = false;
  Future<String?> readValidated(void Function(String) validate) async {
    _validator = validate;
    final text = await read();
    if (text != null) validate(text);
    return text;
  }

  Future<void> clearArchive(String value) async {
    _validator?.call(value);
    if (_usingFiles) {
      await _files.clear(value);
      if (!await (await SharedPreferences.getInstance()).remove(key)) {
        throw StateError('旧聊天恢复源未能清理');
      }
    } else {
      await write(value);
    }
  }

  Future<void> replaceArchive(String value) async {
    _validator?.call(value);
    if (_usingFiles) {
      await _files.write(value, recover: true);
    } else {
      await write(value);
    }
  }

  Future<String?> read() async {
    if (!_files.available)
      return (await SharedPreferences.getInstance()).getString(key);
    _usingFiles = true;
    final stored = await _files.read(validate: _validator);
    if (stored != null) return stored;
    final legacy = (await SharedPreferences.getInstance()).getString(key);
    if (legacy != null) {
      _validator?.call(legacy);
      await _files.write(legacy);
    }
    // Keep the legacy preference as a migration recovery source.
    return legacy;
  }

  Future<void> write(String value) async {
    if (_files.available) {
      await _files.write(value);
      return;
    }
    if (!await (await SharedPreferences.getInstance()).setString(key, value)) {
      throw StateError('聊天记录保存失败');
    }
  }
}

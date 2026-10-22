import 'package:shared_preferences/shared_preferences.dart';

class ChatStorage {
  static const key = 'skivu.conversations.v1';
  Future<String?> read() async =>
      (await SharedPreferences.getInstance()).getString(key);
  Future<void> write(String value) async {
    if (!await (await SharedPreferences.getInstance()).setString(key, value)) {
      throw StateError('聊天记录保存失败');
    }
  }
}

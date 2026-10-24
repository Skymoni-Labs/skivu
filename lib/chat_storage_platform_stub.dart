import 'chat_storage_files.dart';

class PlatformChatStorage implements ChatStorageFiles {
  Future<void> clear(String value) async =>
      throw UnsupportedError('File storage');
  bool get available => false;
  Future<String?> read({void Function(String)? validate}) async => null;
  Future<void> write(String value, {bool recover = false}) async =>
      throw UnsupportedError('File storage');
}

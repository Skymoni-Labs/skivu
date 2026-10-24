abstract interface class ChatStorageFiles {
  bool get available;
  Future<void> clear(String value);
  Future<String?> read({void Function(String)? validate});
  Future<void> write(String value, {bool recover = false});
}

Future<String> saveUpdate(
  Stream<List<int>> stream, {
  required String path,
  required int size,
  required String hash,
  required void Function(int) progress,
  required bool Function() cancelled,
}) => throw UnsupportedError('仅支持 Android 更新');

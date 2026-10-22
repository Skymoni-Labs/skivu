import 'dart:io';
import 'package:crypto/crypto.dart';

class _DigestResult implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

Future<String> saveUpdate(
  Stream<List<int>> stream, {
  required String path,
  required int size,
  required String hash,
  required void Function(int) progress,
  required bool Function() cancelled,
}) async {
  final partial = File('$path.part');
  final output = partial.openWrite();
  final digest = _DigestResult();
  final hasher = sha256.startChunkedConversion(digest);
  var count = 0;
  try {
    await output.addStream(
      stream.map((chunk) {
        if (cancelled()) throw StateError('cancelled');
        count += chunk.length;
        if (count > size) throw const FormatException('更新包大小不匹配');
        hasher.add(chunk);
        progress(count);
        return chunk;
      }),
    );
    await output.close();
    hasher.close();
    if (cancelled()) throw StateError('cancelled');
    if (count != size || digest.value?.toString() != hash)
      throw const FormatException('更新包校验失败');
    await partial.rename(path);
    return path;
  } catch (_) {
    try {
      await output.close();
    } catch (_) {}
    try {
      if (await partial.exists()) await partial.delete();
    } catch (_) {}
    rethrow;
  }
}

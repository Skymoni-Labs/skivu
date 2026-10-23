import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';
import 'package:web/web.dart' as web;

/// Flutter Web cannot read the width/height of an encoded ImageDescriptor.
/// Use the browser decoder for dimensions and validity, keeping the same
/// 16-megapixel bound as the native image validation.
Future<void> validateWebImage(Uint8List bytes) async {
  final mime = bytes.length > 2 && bytes[0] == 0xff && bytes[1] == 0xd8
      ? 'jpeg'
      : bytes.length > 3 && bytes[0] == 0x52 && bytes[1] == 0x49
      ? 'webp'
      : 'png';
  final image = web.HTMLImageElement();
  final loaded = Completer<void>();
  image.onload = ((web.Event _) => loaded.complete()).toJS;
  image.onerror = ((web.Event _) => loaded.completeError(
    const FormatException('Cannot decode image'),
  )).toJS;
  try {
    image.src = 'data:image/$mime;base64,${base64Encode(bytes)}';
    await loaded.future;
    if (image.naturalWidth == 0 ||
        image.naturalHeight == 0 ||
        image.naturalWidth * image.naturalHeight > 16000000)
      throw const FormatException('Image dimensions too large');
  } finally {
    image.onload = null;
    image.onerror = null;
    image.src = '';
  }
}

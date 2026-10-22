import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'media_picker_session.dart';
import 'state.dart';

/// Store a small, metadata-free image with the role so backups stay portable.
Future<Uint8List> normalizeCharacterAvatar(Uint8List bytes) async {
  if (bytes.isEmpty || bytes.length > 3 * 1024 * 1024) {
    throw const FormatException('Invalid avatar size');
  }
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? image;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    if (descriptor.width > 8192 || descriptor.height > 8192) {
      throw const FormatException('Invalid avatar dimensions');
    }
    final scale = math.min(
      1.0,
      256 / math.max(descriptor.width, descriptor.height),
    );
    codec = await descriptor.instantiateCodec(
      targetWidth: math.max(1, (descriptor.width * scale).round()),
      targetHeight: math.max(1, (descriptor.height * scale).round()),
    );
    image = (await codec.getNextFrame()).image;
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null || data.lengthInBytes > 300 * 1024) {
      throw const FormatException('Avatar could not be resized');
    }
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    image?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer.dispose();
  }
}

Future<Uint8List?> pickCharacterAvatar() =>
    mediaPickerSession.run(MediaDestination.characterAvatar, () async {
      final file = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 85,
        requestFullMetadata: false,
      );
      if (file == null) return null;
      return normalizeCharacterAvatar(await file.readAsBytes());
    });

class CharacterAvatar extends StatelessWidget {
  const CharacterAvatar({
    super.key,
    required this.persona,
    this.size = 32,
    this.bytes,
    this.square = false,
    this.showDefault = false,
  });
  final Persona persona;
  final double size;
  final Uint8List? bytes;
  final bool square;
  final bool showDefault;
  @override
  Widget build(BuildContext context) {
    final picture = showDefault ? null : bytes ?? persona.avatar;
    Widget fallback() => ColoredBox(
      color: persona.color.withValues(alpha: .12),
      child: Icon(persona.icon, size: size * .56, color: ink),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(square ? 7 : size / 2),
      child: SizedBox.square(
        dimension: size,
        child: picture == null
            ? fallback()
            : Image.memory(
                picture,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => fallback(),
              ),
      ),
    );
  }
}

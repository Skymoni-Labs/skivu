import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'chat_interaction.dart';
import 'widgets.dart';

const _attachmentChannel = MethodChannel('skivu/chat_attachment');
const _attachmentMimeExtensions = <String, String>{
  'image/png': 'png',
  'image/jpeg': 'jpg',
  'image/webp': 'webp',
  'video/mp4': 'mp4',
  'video/webm': 'webm',
  'audio/webm': 'webm',
  'audio/ogg': 'ogg',
  'audio/mp4': 'm4a',
  'audio/mpeg': 'mp3',
  'audio/wav': 'wav',
  'application/pdf': 'pdf',
  'application/octet-stream': 'bin',
  'text/plain': 'txt',
  'application/zip': 'zip',
};

/// A bounded projection of a validated archive attachment. Revalidated at the
/// native boundary; names never become paths and MIME types are allowlisted.
@immutable
class NativeChatAttachment {
  const NativeChatAttachment._(this.bytes, this.mime, this.name);
  final Uint8List bytes;
  final String mime, name;

  static NativeChatAttachment parse(Map<String, dynamic> event) {
    final clean = cleanChatInteraction(event);
    if (clean == null ||
        !const {
          'image',
          'video',
          'audio',
          'music',
          'file',
        }.contains(clean['kind'])) {
      throw const FormatException('附件格式不正确或超过 2MB。');
    }
    final payload = clean['payload'] as Map;
    final data = payload['data'] as String;
    final mime = data.substring(5, data.indexOf(';'));
    final extension = _attachmentMimeExtensions[mime];
    if (extension == null) throw const FormatException('不支持的附件类型。');
    var stem = (payload['name'] as String)
        .replaceAll(
          RegExp(r'[\\/\x00-\x1f\x7f<>:"|?*\u202a-\u202e\u2066-\u2069]'),
          '_',
        )
        .replaceAll(RegExp(r'^\.+|[. ]+$'), '')
        .trim();
    if (stem.contains('.')) stem = stem.substring(0, stem.lastIndexOf('.'));
    if (stem.isEmpty) stem = 'chat-attachment';
    if (RegExp(
      r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])$',
      caseSensitive: false,
    ).hasMatch(stem))
      stem = 'chat-$stem';
    stem = String.fromCharCodes(stem.runes.take(90));
    return NativeChatAttachment._(
      base64Decode(data.split(',').last),
      mime,
      '$stem.$extension',
    );
  }

  Map<String, Object> get arguments => {
    'bytes': bytes,
    'mime': mime,
    'name': name,
  };
}

Future<void> openNativeChatAttachment(
  BuildContext context,
  Map<String, dynamic> event,
) async {
  try {
    final attachment = NativeChatAttachment.parse(event);
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      if (context.mounted) toast(context, '此平台暂不支持系统打开附件，可选择另存。');
      return;
    }
    await _attachmentChannel.invokeMethod<bool>('open', attachment.arguments);
  } on FormatException catch (error) {
    if (context.mounted) toast(context, error.message);
  } on PlatformException catch (error) {
    if (context.mounted)
      toast(
        context,
        error.code == 'NO_VIEWER' ? '未找到可打开此附件的应用，请先另存。' : '附件未能打开，请重试。',
      );
  } catch (_) {
    if (context.mounted) toast(context, '附件未能打开，请重试。');
  }
}

Future<void> saveNativeChatAttachment(
  BuildContext context,
  Map<String, dynamic> event,
) async {
  try {
    final attachment = NativeChatAttachment.parse(event);
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      final saved = await _attachmentChannel.invokeMethod<bool>(
        'save',
        attachment.arguments,
      );
      if (saved != true) return; // System picker cancellation is normal.
    } else if (kIsWeb) {
      await XFile.fromData(
        attachment.bytes,
        mimeType: attachment.mime,
        name: attachment.name,
      ).saveTo(attachment.name);
    } else {
      final location = await getSaveLocation(suggestedName: attachment.name);
      if (location == null) return;
      await XFile.fromData(
        attachment.bytes,
        mimeType: attachment.mime,
        name: attachment.name,
      ).saveTo(location.path);
    }
    if (context.mounted) toast(context, '附件已保存');
  } on FormatException catch (error) {
    if (context.mounted) toast(context, error.message);
  } catch (_) {
    if (context.mounted) toast(context, '附件未保存，请检查所选位置后重试。');
  }
}

/// System file selection adds a local archive attachment, not model input.
Future<Map<String, dynamic>?> pickNativeChatFile({required String kind}) async {
  final music = kind == 'music';
  final file = await openFile(
    acceptedTypeGroups: [
      XTypeGroup(
        label: music ? '音频' : '文件',
        extensions: music
            ? const ['mp3', 'm4a', 'ogg', 'wav', 'webm']
            : const ['pdf', 'txt', 'zip', 'bin'],
      ),
    ],
  );
  if (file == null) return null;
  if (await file.length() > 2 * 1024 * 1024)
    throw const FormatException('附件不能超过 2MB。');
  final suffix = file.name.split('.').last.toLowerCase();
  final mime = switch (suffix) {
    'mp3' => 'audio/mpeg',
    'm4a' => 'audio/mp4',
    'ogg' => 'audio/ogg',
    'wav' => 'audio/wav',
    'webm' => 'audio/webm',
    'pdf' => 'application/pdf',
    'txt' => 'text/plain',
    'zip' => 'application/zip',
    'bin' => 'application/octet-stream',
    _ => throw const FormatException('不支持此附件类型。'),
  };
  final bytes = await file.readAsBytes();
  final event = cleanChatInteraction({
    'id': 'native-${DateTime.now().microsecondsSinceEpoch}',
    'kind': music ? 'music' : 'file',
    'created': DateTime.now().toIso8601String(),
    'user': true,
    'payload': {
      'name': file.name,
      'data': 'data:$mime;base64,${base64Encode(bytes)}',
    },
  });
  if (event == null) throw const FormatException('附件格式不正确或超过 2MB。');
  return event;
}

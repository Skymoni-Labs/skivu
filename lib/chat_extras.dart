import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'media_picker_session.dart';
import 'state.dart';
import 'widgets.dart';

Future<Uint8List> normalizeChatPhoto(Uint8List bytes) async {
  if (bytes.isEmpty || bytes.length > 6 * 1024 * 1024)
    throw const FormatException('图片过大');
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  ui.ImageDescriptor? descriptor;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    if (descriptor.width > 8192 || descriptor.height > 8192)
      throw const FormatException('图片尺寸过大');
    for (final side in [1024, 768, 512, 384, 256]) {
      final ratio =
          side /
          (descriptor.width > descriptor.height
              ? descriptor.width
              : descriptor.height);
      final codec = await descriptor.instantiateCodec(
        targetWidth: (descriptor.width * ratio.clamp(0, 1)).round().clamp(
          1,
          1024,
        ),
        targetHeight: (descriptor.height * ratio.clamp(0, 1)).round().clamp(
          1,
          1024,
        ),
      );
      final image = (await codec.getNextFrame()).image;
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        if (data != null && data.lengthInBytes <= 144 * 1024)
          return data.buffer.asUint8List(
            data.offsetInBytes,
            data.lengthInBytes,
          );
      } finally {
        image.dispose();
        codec.dispose();
      }
    }
    throw const FormatException('图片无法压缩，请选择其他图片');
  } finally {
    descriptor?.dispose();
    buffer.dispose();
  }
}

class _SpeechDraft {
  final channel = const MethodChannel('skivu/voice_call');
  Completer<String>? pending;
  Future<String> listen() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android)
      throw const FormatException('请在安卓客户端使用麦克风，或选择描述语音。');
    final done = pending = Completer<String>();
    done.future.ignore();
    channel.setMethodCallHandler((event) async {
      if (done.isCompleted) return;
      final args = event.arguments is Map ? event.arguments as Map : {};
      if (event.method == 'result')
        done.complete(args['text']?.toString() ?? '');
      if (event.method == 'recognitionError')
        done.completeError(const FormatException('未能识别语音，请重试或改为描述语音。'));
    });
    try {
      final result = await channel.invokeMethod<String>('listen', {
        'requestPermission': true,
      });
      if (result == 'permission_required')
        throw const FormatException('请允许麦克风权限。');
      return await done.future.timeout(const Duration(seconds: 45));
    } finally {
      if (identical(pending, done)) {
        pending = null;
        await channel.invokeMethod('stopListening');
        channel.setMethodCallHandler(null);
      }
    }
  }

  void cancel() {
    if (pending?.isCompleted == false)
      pending!.completeError(const FormatException('已取消识别'));
  }
}

Future<bool> composeChatMedia(
  BuildContext context, {
  required bool photo,
  bool? streamingOverride,
  bool initiallyReal = false,
}) async {
  final chatId = demo.conversations[demo.conversation].id;
  final text = TextEditingController();
  final speech = _SpeechDraft();
  bool described = !initiallyReal, busy = false;
  String? data, error;
  bool sent = false;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialog) => StatefulBuilder(
      builder: (c, change) => AlertDialog(
        title: Text(photo ? '发送图片' : '发送语音'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SegmentedButton<bool>(
                segments: [
                  ButtonSegment(
                    value: true,
                    label: Text(photo ? '描述图片' : '描述语音'),
                  ),
                  ButtonSegment(
                    value: false,
                    label: Text(photo ? '真实图片' : '麦克风'),
                  ),
                ],
                selected: {described},
                onSelectionChanged: busy
                    ? null
                    : (v) => change(() {
                        described = v.first;
                        error = null;
                      }),
              ),
              const SizedBox(height: 16),
              if (photo && !described) ...[
                if (data != null)
                  Image.memory(
                    base64Decode(data!.split(',').last),
                    height: 150,
                    fit: BoxFit.contain,
                  ),
                OutlinedButton.icon(
                  onPressed: busy
                      ? null
                      : () async {
                          change(() {
                            busy = true;
                            error = null;
                          });
                          try {
                            final source =
                                await showModalBottomSheet<ImageSource>(
                                  context: c,
                                  builder: (sheet) => SafeArea(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        ListTile(
                                          leading: const Icon(
                                            Icons.photo_library_outlined,
                                          ),
                                          title: const Text('从相册选择'),
                                          onTap: () => Navigator.pop(
                                            sheet,
                                            ImageSource.gallery,
                                          ),
                                        ),
                                        if (!kIsWeb)
                                          ListTile(
                                            leading: const Icon(
                                              Icons.camera_alt_outlined,
                                            ),
                                            title: const Text('拍摄照片'),
                                            onTap: () => Navigator.pop(
                                              sheet,
                                              ImageSource.camera,
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                );
                            if (source == null) return;
                            final file = await mediaPickerSession.run(
                              MediaDestination.chatImage,
                              () => ImagePicker().pickImage(
                                source: source,
                                maxWidth: 1600,
                                maxHeight: 1600,
                                imageQuality: 85,
                                requestFullMetadata: false,
                              ),
                            );
                            if (file != null) {
                              final bytes = await normalizeChatPhoto(
                                await file.readAsBytes(),
                              );
                              if (c.mounted)
                                change(
                                  () => data =
                                      'data:image/png;base64,${base64Encode(bytes)}',
                                );
                            }
                          } catch (_) {
                            if (c.mounted)
                              change(() => error = '图片未导入，请选择有效图片。');
                          } finally {
                            if (c.mounted) change(() => busy = false);
                          }
                        },
                  icon: const Icon(Icons.photo_library_outlined),
                  label: Text(busy ? '正在导入…' : '选择或拍摄照片'),
                ),
                const Text(
                  '压缩后的图片会发送给当前模型，需要模型和接口支持图片理解。',
                  style: TextStyle(fontSize: 12, height: 1.6),
                ),
              ],
              if (!photo && !described) ...[
                OutlinedButton.icon(
                  onPressed: busy
                      ? () => speech.cancel()
                      : () async {
                          change(() {
                            busy = true;
                            error = null;
                          });
                          try {
                            final value = await speech.listen();
                            if (c.mounted) change(() => text.text = value);
                          } catch (e) {
                            if (c.mounted)
                              change(
                                () => error = e is FormatException
                                    ? e.message.toString()
                                    : '语音识别暂不可用，请重试或输入文字。',
                              );
                          } finally {
                            if (c.mounted) change(() => busy = false);
                          }
                        },
                  icon: const Icon(Icons.mic_none),
                  label: Text(busy ? '取消识别' : '开始语音识别'),
                ),
                const Text(
                  '使用手机的语音识别，将转写内容作为语音消息交给角色。',
                  style: TextStyle(fontSize: 12, height: 1.6),
                ),
              ],
              const SizedBox(height: 12),
              TextField(
                controller: text,
                minLines: 3,
                maxLines: 7,
                maxLength: 10000,
                decoration: InputDecoration(
                  labelText: photo
                      ? (described ? '照片内容描述' : '图片说明（可选）')
                      : (described ? '语音内容' : '识别结果，可修改'),
                  hintText: photo ? '例如：傍晚的海边，我穿着白色衬衫。' : '输入想对角色说的话…',
                  alignLabelWithHint: true,
                ),
              ),
              if (described)
                Text(
                  photo ? '以照片描述呈现，角色会收到你描述的照片内容。' : '以语音气泡呈现，角色会读取这些文字，无需录音。',
                  style: const TextStyle(fontSize: 12, height: 1.6),
                ),
              if (error != null)
                Text(error!, style: const TextStyle(color: Color(0xffa62f28))),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              speech.cancel();
              Navigator.pop(c);
            },
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: busy
                ? null
                : () {
                    if (demo.conversations[demo.conversation].id != chatId) {
                      change(() => error = '对话已切换，请重新发送。');
                      return;
                    }
                    if ((described || !photo) && text.text.trim().isEmpty) {
                      change(() => error = '请先填写内容。');
                      return;
                    }
                    if (photo && !described && data == null) {
                      change(() => error = '请先选择图片。');
                      return;
                    }
                    final ok = demo.send(
                      text.text.trim().isEmpty ? '照片' : text.text,
                      kind: photo ? (described ? 'photo' : 'image') : 'voice',
                      described: described,
                      imageData: photo && !described ? data : null,
                      streamingOverride: streamingOverride,
                    );
                    if (ok) {
                      sent = true;
                      Navigator.pop(c);
                    } else {
                      change(() => error = demo.lastError ?? '当前无法发送，请等待回复完成。');
                    }
                  },
            child: Text(
              demo.conversations[demo.conversation].confirmBeforeReply ||
                      demo
                          .conversations[demo.conversation]
                          .queuedMessages
                          .isNotEmpty
                  ? '加入待发送'
                  : '发送',
            ),
          ),
        ],
      ),
    ),
  );
  speech.cancel();
  await Future<void>.delayed(const Duration(milliseconds: 300));
  text.dispose();
  return sent;
}

Future<void> confirmChatBatch(
  BuildContext context, {
  TextEditingController? input,
  bool? streamingOverride,
}) async {
  if (!demo.confirmPending(streamingOverride: streamingOverride)) {
    if (demo.lastError != null && context.mounted)
      toast(context, demo.lastError!);
  } else if (context.mounted) {
    FocusScope.of(context).unfocus();
  }
}

class QueuedSendBar extends StatelessWidget {
  const QueuedSendBar({super.key, required this.input, this.beforeConfirm});
  final TextEditingController input;
  final VoidCallback? beforeConfirm;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([demo, input]),
    builder: (context, _) {
      final chat = demo.conversations[demo.conversation],
          count = demo.conversations[demo.conversation].queuedMessages.length;
      if (!chat.confirmBeforeReply && count == 0)
        return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                count == 0 ? '分条输入，确认后统一回复' : '$count 条待发送',
                style: const TextStyle(fontSize: 12),
              ),
            ),
            if (count > 0)
              IconButton(
                tooltip: '清空待发送消息',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.delete_outline, size: 19),
                onPressed: demo.streaming
                    ? null
                    : () async {
                        final yes = await showDialog<bool>(
                          context: context,
                          builder: (c) => AlertDialog(
                            title: const Text('清空待发送消息？'),
                            content: Text('移除这$count条尚未提交的消息。'),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(c),
                                child: const Text('取消'),
                              ),
                              TextButton(
                                onPressed: () => Navigator.pop(c, true),
                                child: const Text('清空'),
                              ),
                            ],
                          ),
                        );
                        if (yes == true &&
                            identical(
                              chat,
                              demo.conversations[demo.conversation],
                            ))
                          demo.discardQueued();
                      },
              ),
            FilledButton(
              onPressed: demo.streaming || count == 0
                  ? null
                  : () {
                      beforeConfirm?.call();
                      confirmChatBatch(context, input: input);
                    },
              child: const Text('确认发送'),
            ),
          ],
        ),
      );
    },
  );
}

class TypedMessageBody extends StatelessWidget {
  const TypedMessageBody({super.key, required this.message});
  final Message message;
  @override
  Widget build(BuildContext context) {
    final m = message;
    if (m.kind == 'sticker') {
      final data = demo.stickerFor(m.stickerId)?.data;
      return data == null
          ? Text('[表情包：${m.text}]')
          : Image.memory(
              base64Decode(data.split(',').last),
              width: 150,
              height: 150,
              fit: BoxFit.contain,
              semanticLabel: '表情包 ${m.text}',
              errorBuilder: (_, _, _) => Text('[表情包：${m.text}]'),
            );
    }
    if (m.kind == 'voice')
      return Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(top: 8),
          dense: true,
          leading: const Icon(Icons.graphic_eq),
          title: Text(
            m.described ? '语音 · 文字描述' : '语音 · 识别转写',
            style: const TextStyle(fontSize: 13),
          ),
          subtitle: const Text('点击查看内容', style: TextStyle(fontSize: 10)),
          children: [SelectableText(m.text)],
        ),
      );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (m.imageData != null)
          Image.memory(
            base64Decode(m.imageData!.split(',').last),
            width: 220,
            height: 180,
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) => const Text('图片无法显示'),
          )
        else
          const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.photo_outlined, size: 21),
              SizedBox(width: 6),
              Text('照片 · 内容描述', style: TextStyle(fontSize: 12)),
            ],
          ),
        const SizedBox(height: 8),
        SelectableText(m.text),
      ],
    );
  }
}

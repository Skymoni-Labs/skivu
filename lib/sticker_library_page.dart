import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'companion_library.dart';
import 'media_picker_session.dart';
import 'state.dart';
import 'widgets.dart';

class StickerLibraryPage extends StatefulWidget {
  const StickerLibraryPage({super.key});
  @override
  State<StickerLibraryPage> createState() => _StickerLibraryPageState();
}

class _StickerLibraryPageState extends State<StickerLibraryPage> {
  String? groupId;
  bool importing = false;
  Future<void> groupEditor([StickerGroup? group]) async {
    final input = TextEditingController(text: group?.name ?? '');
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(group == null ? '新建表情分组' : '重命名分组'),
        content: TextField(
          controller: input,
          maxLength: 40,
          decoration: const InputDecoration(labelText: '分组名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (input.text.trim().isNotEmpty) Navigator.pop(c, true);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (yes == true && mounted) {
      if (group == null) {
        if (demo.stickerGroups.length >= 30) {
          toast(context, '最多30个表情分组。');
        } else {
          final next = StickerGroup(libraryId('stickers'), input.text.trim());
          demo.stickerGroups.add(next);
          groupId = next.id;
        }
      } else {
        group.name = input.text.trim();
      }
      demo.saveLibrary();
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    input.dispose();
  }

  void retire(Iterable<StickerAsset> values) {
    for (final sticker in values) {
      sticker.active = false;
    }
    final used = demo.conversations
        .expand((c) => c.messages)
        .map((m) => m.stickerId)
        .toSet();
    demo.stickers.removeWhere((s) => !s.active && !used.contains(s.id));
    demo.saveLibrary();
  }

  Future<void> deleteGroup(StickerGroup group) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('删除“${group.name}”？'),
        content: const Text('从表情库移除该组及组内表情，已经发送的表情会保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (yes == true && mounted) {
      retire(demo.stickers.where((s) => s.groupId == group.id).toList());
      demo.stickerGroups.remove(group);
      setState(() => groupId = null);
      demo.saveLibrary();
    }
  }

  Future<void> importSticker() async {
    setState(() => importing = true);
    try {
      final file = await mediaPickerSession.run(
        MediaDestination.sticker,
        () => ImagePicker().pickImage(
          source: ImageSource.gallery,
          requestFullMetadata: false,
        ),
      );
      if (file == null) return;
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty || bytes.length > 512 * 1024)
        throw const FormatException('请选择512KB以内的表情图片，支持PNG、JPG、WebP和GIF。');
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      ui.ImageDescriptor? descriptor;
      try {
        descriptor = await ui.ImageDescriptor.encoded(buffer);
        if (descriptor.width > 4096 || descriptor.height > 4096)
          throw const FormatException('表情图片尺寸过大，请先缩小。');
      } finally {
        descriptor?.dispose();
        buffer.dispose();
      }
      final mime =
          bytes.length > 3 && bytes[0] == 71 && bytes[1] == 73 && bytes[2] == 70
          ? 'gif'
          : bytes[0] == 137
          ? 'png'
          : bytes[0] == 255
          ? 'jpeg'
          : bytes.length >= 12 &&
                String.fromCharCodes(bytes.take(4)) == 'RIFF' &&
                String.fromCharCodes(bytes.skip(8).take(4)) == 'WEBP'
          ? 'webp'
          : null;
      if (mime == null) throw const FormatException('请选择PNG、JPG、WebP或GIF表情图片。');
      final data = 'data:image/$mime;base64,${base64Encode(bytes)}';
      if (demo.stickers.length >= 200 ||
          demo.stickers.fold<int>(0, (n, s) => n + s.data.length) +
                  data.length >
              8500000)
        throw const FormatException('表情库已满，请先移除不用的表情。');
      if (demo.stickerGroups.isEmpty)
        demo.stickerGroups.add(StickerGroup(libraryId('stickers'), '我的表情'));
      final group =
          demo.stickerGroups.where((g) => g.id == groupId).firstOrNull ??
          demo.stickerGroups.first;
      final name = file.name.replaceFirst(RegExp(r'\.[^.]+$'), '').trim();
      final sticker = StickerAsset(
        id: libraryId('sticker'),
        groupId: group.id,
        name: name.isEmpty ? '新表情' : name.characters.take(80).join(),
        data: data,
      );
      demo.stickers.add(sticker);
      groupId = group.id;
      demo.saveLibrary();
      if (mounted) await editSticker(sticker);
    } on FormatException catch (e) {
      if (mounted) toast(context, e.message.toString());
    } catch (_) {
      if (mounted) toast(context, '图片未导入，请选择有效的表情图片。');
    } finally {
      if (mounted) setState(() => importing = false);
    }
  }

  Future<void> editSticker(StickerAsset sticker) async {
    final input = TextEditingController(text: sticker.name);
    var selected = demo.stickerGroups.any((g) => g.id == sticker.groupId)
        ? sticker.groupId
        : demo.stickerGroups.first.id;
    final action = await showDialog<String>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, change) => AlertDialog(
          title: const Text('表情设置'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.memory(
                base64Decode(sticker.data.split(',').last),
                height: 120,
                fit: BoxFit.contain,
              ),
              TextField(
                controller: input,
                maxLength: 80,
                decoration: const InputDecoration(
                  labelText: '表情名称',
                  helperText: '角色会通过这个名称理解表情含义。',
                ),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: selected,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '分组'),
                items: [
                  for (final group in demo.stickerGroups)
                    DropdownMenuItem(value: group.id, child: Text(group.name)),
                ],
                onChanged: (v) => change(() => selected = v!),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, 'remove'),
              child: const Text('移除'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                if (input.text.trim().isNotEmpty) Navigator.pop(c, 'save');
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (action == 'save') {
      sticker.name = input.text.trim();
      sticker.groupId = selected;
      demo.saveLibrary();
    }
    if (action == 'remove' && mounted) {
      final yes = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('移除这个表情？'),
          content: const Text('已经发送的表情会保留。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('移除'),
            ),
          ],
        ),
      );
      if (yes == true) retire([sticker]);
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    input.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: demo,
    builder: (context, _) {
      final selected = demo.stickerGroups
          .where((g) => g.id == groupId)
          .firstOrNull;
      final values = demo.stickers
          .where(
            (s) => s.active && (selected == null || s.groupId == selected.id),
          )
          .toList();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PageHeading('我的收藏', '表情包', '添加自己的图片，按分组整理，在三种聊天界面中共用。'),
          Wrap(
            spacing: 10,
            children: [
              FilledButton.icon(
                onPressed: importing ? null : importSticker,
                icon: const Icon(Icons.add_photo_alternate_outlined),
                label: Text(importing ? '正在添加…' : '添加表情'),
              ),
              OutlinedButton.icon(
                onPressed: () => groupEditor(),
                icon: const Icon(Icons.create_new_folder_outlined),
                label: const Text('新建分组'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                ChoiceChip(
                  label: const Text('全部'),
                  selected: selected == null,
                  onSelected: (_) => setState(() => groupId = null),
                ),
                for (final group in demo.stickerGroups)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: ChoiceChip(
                      label: Text(group.name),
                      selected: selected == group,
                      onSelected: (_) => setState(() => groupId = group.id),
                    ),
                  ),
              ],
            ),
          ),
          if (selected != null)
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => groupEditor(selected),
                  child: const Text('重命名分组'),
                ),
                TextButton(
                  onPressed: () => deleteGroup(selected),
                  child: const Text('删除分组'),
                ),
              ],
            ),
          const SizedBox(height: 12),
          if (values.isEmpty)
            const Padding(
              padding: EdgeInsets.all(25),
              child: Text('还没有表情，添加一张喜欢的图片吧。', textAlign: TextAlign.center),
            ),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: values.length,
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 135,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: .9,
            ),
            itemBuilder: (c, i) => InkWell(
              onTap: () => editSticker(values[i]),
              borderRadius: BorderRadius.circular(14),
              child: Pane(
                padding: const EdgeInsets.all(8),
                child: Column(
                  children: [
                    Expanded(
                      child: Image.memory(
                        base64Decode(values[i].data.split(',').last),
                        fit: BoxFit.contain,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      values[i].name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      );
    },
  );
}

Future<bool> showStickerPicker(
  BuildContext context, {
  bool? streamingOverride,
}) async {
  var groupId = '';
  bool sent = false;
  final chatId = demo.conversations[demo.conversation].id;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (sheet) => StatefulBuilder(
      builder: (sheet, change) => AnimatedBuilder(
        animation: demo,
        builder: (sheet, _) => SizedBox(
          height: MediaQuery.sizeOf(context).height * .52,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(child: label('表情包', size: 20)),
                    TextButton(
                      onPressed: () {
                        Navigator.pop(sheet);
                        Navigator.of(context).pushReplacementNamed('/stickers');
                      },
                      child: const Text('管理表情'),
                    ),
                  ],
                ),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      ChoiceChip(
                        label: const Text('全部'),
                        selected: groupId.isEmpty,
                        onSelected: (_) => change(() => groupId = ''),
                      ),
                      for (final group in demo.stickerGroups)
                        Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: ChoiceChip(
                            label: Text(group.name),
                            selected: groupId == group.id,
                            onSelected: (_) => change(() => groupId = group.id),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                Expanded(
                  child: Builder(
                    builder: (c) {
                      final values = demo.stickers
                          .where(
                            (s) =>
                                s.active &&
                                (groupId.isEmpty || s.groupId == groupId),
                          )
                          .toList();
                      if (values.isEmpty)
                        return const Center(child: Text('还没有表情，先去“管理表情”添加。'));
                      return GridView.builder(
                        itemCount: values.length,
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 110,
                              mainAxisSpacing: 10,
                              crossAxisSpacing: 10,
                            ),
                        itemBuilder: (c, i) => Semantics(
                          label: '发送表情 ${values[i].name}',
                          button: true,
                          child: InkWell(
                            onTap: () {
                              if (demo.conversations[demo.conversation].id !=
                                  chatId) {
                                toast(context, '对话已切换，请重新选择。');
                                return;
                              }
                              if (demo.send(
                                values[i].name,
                                kind: 'sticker',
                                stickerId: values[i].id,
                                streamingOverride: streamingOverride,
                              )) {
                                sent = true;
                                Navigator.pop(sheet);
                              } else {
                                toast(context, demo.lastError ?? '当前无法发送。');
                              }
                            },
                            child: Image.memory(
                              base64Decode(values[i].data.split(',').last),
                              fit: BoxFit.contain,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  return sent;
}

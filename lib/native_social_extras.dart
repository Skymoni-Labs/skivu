import 'dart:convert';
import 'dart:typed_data';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show compute, kIsWeb, defaultTargetPlatform;
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;
import 'package:qr/qr.dart' as qr;
import 'package:zxing2/qrcode.dart' as zx;

import 'chat_controls.dart';
import 'character_avatar.dart';
import 'social_activity.dart';
import 'state.dart';
import 'ui_plugins.dart';
import 'virtual_wallet.dart';
import 'legacy_social_migration.dart';
import 'media_picker_session.dart';
import 'social_post_draft.dart';
export 'social_post_draft.dart' show normalizeSocialPhoto;

/// Native secondary social pages. All mutations use the existing local stores.
class NativeSocialExtras extends StatefulWidget {
  const NativeSocialExtras({
    super.key,
    required this.page,
    required this.mode,
    required this.navigate,
    required this.go,
    required this.onBack,
    this.onRole,
  });

  final String page;
  final ChatUiMode mode;
  final ValueChanged<String> navigate, go;
  final VoidCallback onBack;
  final ValueChanged<String>? onRole;

  @override
  State<NativeSocialExtras> createState() => _NativeSocialExtrasState();
}

class _NativeSocialExtrasState extends State<NativeSocialExtras> {
  final _post = TextEditingController();
  final List<String> _images = [];
  bool _picking = false;
  bool _draftLoading = false,
      _publishing = false,
      _restoringDraft = false,
      _draftPublished = false;
  int? _publishAttempt;
  int _draftRestoreEpoch = 0;
  Timer? _draftTimer;
  String get _channel => widget.mode == ChatUiMode.qq ? 'qq' : 'wx';
  Color get _accent => widget.mode == ChatUiMode.qq
      ? const Color(0xff0099ed)
      : const Color(0xff07a960);
  String get _self => demo.userCard['称呼']?.trim().isNotEmpty == true
      ? demo.userCard['称呼']!
      : '我';
  String get _title => switch (widget.page) {
    'moments' => widget.mode == ChatUiMode.qq ? '好友动态' : '朋友圈',
    'compose' => widget.mode == ChatUiMode.qq ? '写说说' : '发表动态',
    'albums' => '相册',
    'favorites' => '收藏',
    'services' => '服务',
    'wallet' => '钱包',
    'wallet-records' => '零钱明细',
    'cashier' => '收付款',
    'scan' => '扫一扫',
    'me' || 'profile' => '个人资料',
    'calls' => '通话记录',
    'settings' => '设置',
    _ => 'Skivu',
  };

  @override
  void initState() {
    super.initState();
    demo.addListener(_refresh);
    socialActivity.addListener(_refresh);
    virtualWallet.addListener(_refresh);
    legacySocialMigration.addListener(_refresh);
    _post.addListener(_draftChanged);
    if (widget.page == 'compose') unawaited(_restoreDraft());
  }

  @override
  void didUpdateWidget(NativeSocialExtras oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.page == 'compose' &&
        (oldWidget.page != widget.page || oldWidget.mode != widget.mode)) {
      _draftTimer?.cancel();
      if (!_draftLoading && !_draftPublished)
        unawaited(
          socialPostDrafts.save(
            oldWidget.mode == ChatUiMode.qq ? 'qq' : 'wx',
            _post.text,
            List.of(_images),
            publishAttempt: _publishAttempt,
          ),
        );
    }
    if (widget.page == 'compose' &&
        (oldWidget.page != 'compose' || oldWidget.mode != widget.mode))
      unawaited(_restoreDraft());
  }

  Future<void> _restoreDraft() async {
    final epoch = ++_draftRestoreEpoch;
    final channel = _channel;
    _draftLoading = true;
    try {
      final draft = await socialPostDrafts.read(channel);
      if (!mounted ||
          widget.page != 'compose' ||
          _channel != channel ||
          epoch != _draftRestoreEpoch)
        return;
      _restoringDraft = true;
      _post.text = draft?.text ?? '';
      _images
        ..clear()
        ..addAll(draft?.images ?? []);
      _publishAttempt = draft?.publishAttempt;
      _draftPublished = false;
    } catch (_) {
      _notice('动态草稿读取失败，原记录已保留。');
    } finally {
      _restoringDraft = false;
      if (mounted && epoch == _draftRestoreEpoch)
        setState(() => _draftLoading = false);
    }
  }

  void _draftChanged() {
    if (_restoringDraft ||
        _draftLoading ||
        _publishing ||
        widget.page != 'compose')
      return;
    _publishAttempt = null;
    _draftTimer?.cancel();
    _draftTimer = Timer(
      const Duration(milliseconds: 300),
      () => unawaited(_saveDraft()),
    );
  }

  Future<String?> _saveDraft() async {
    final failure = await socialPostDrafts.save(
      _channel,
      _post.text,
      List.of(_images),
      publishAttempt: _publishAttempt,
    );
    _notice(failure);
    return failure;
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    demo.removeListener(_refresh);
    socialActivity.removeListener(_refresh);
    virtualWallet.removeListener(_refresh);
    legacySocialMigration.removeListener(_refresh);
    _draftTimer?.cancel();
    if (widget.page == 'compose' &&
        !_draftLoading &&
        !_publishing &&
        !_draftPublished)
      unawaited(
        socialPostDrafts.save(
          _channel,
          _post.text,
          List.of(_images),
          publishAttempt: _publishAttempt,
        ),
      );
    _post.removeListener(_draftChanged);
    _post.dispose();
    super.dispose();
  }

  void _notice(String? text) {
    if (text != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  @override
  Widget build(BuildContext context) => Material(
    color: const Color(0xfff2f2f2),
    child: SafeArea(
      bottom: true,
      child: Column(
        children: [
          Container(
            height: 56,
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: Color(0xffdddddd))),
            ),
            child: Row(
              children: [
                IconButton(
                  tooltip: '返回',
                  onPressed: widget.onBack,
                  icon: const Icon(Icons.arrow_back_ios_new, size: 20),
                ),
                Expanded(
                  child: Text(
                    _title,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (widget.page == 'moments')
                  IconButton(
                    tooltip: '发表动态',
                    onPressed: () => widget.navigate('compose'),
                    icon: const Icon(Icons.camera_alt_outlined),
                  ),
                if (widget.page == 'compose')
                  TextButton(
                    onPressed: _picking || _draftLoading || _publishing
                        ? null
                        : _publish,
                    child: Text('发表', style: TextStyle(color: _accent)),
                  ),
              ],
            ),
          ),
          Expanded(child: _body()),
        ],
      ),
    ),
  );

  Widget _list(List<Widget> children) => ListView(
    key: PageStorageKey('social-extra-${widget.mode.name}-${widget.page}'),
    padding: const EdgeInsets.only(bottom: 24),
    keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
    children: children,
  );

  Widget _note(String text) => Padding(
    padding: const EdgeInsets.all(20),
    child: Text(
      text,
      style: const TextStyle(color: Color(0xff777777), fontSize: 13),
    ),
  );

  Widget _row(
    String text,
    IconData icon,
    VoidCallback action, {
    String? subtitle,
  }) => Material(
    color: Colors.white,
    child: ListTile(
      leading: Icon(icon, color: _accent),
      title: Text(text),
      subtitle: subtitle == null ? null : Text(subtitle),
      trailing: const Icon(Icons.chevron_right, color: Colors.grey),
      onTap: action,
    ),
  );

  Widget _body() => switch (widget.page) {
    'moments' => _moments(),
    'compose' => _compose(),
    'albums' => _albums(),
    'favorites' => _favorites(),
    'services' || 'wallet' => _wallet(),
    'wallet-records' => _records(),
    'cashier' => _cashier(),
    'scan' => _scan(),
    'me' || 'profile' => _profile(),
    'calls' => _calls(),
    'settings' => _settings(),
    _ => _list([
      _note('此功能可从原版工作区继续使用。'),
      _row('打开原版设置', Icons.settings_outlined, () => widget.go('/settings')),
    ]),
  };

  Persona? _role(String id) =>
      demo.personas.where((p) => p.id == id).firstOrNull;
  String _name(String id) => id == 'self' ? _self : _role(id)?.name ?? '已移除的角色';
  Widget _avatar(String id) {
    if (id == 'self') return const UserAvatar(size: 42);
    final role = _role(id);
    return CircleAvatar(
      backgroundColor: role?.color ?? Colors.grey,
      backgroundImage: role?.avatar == null ? null : MemoryImage(role!.avatar!),
      child: role?.avatar == null
          ? Icon(role?.icon ?? Icons.person_outline, color: Colors.white)
          : null,
    );
  }

  Widget _moments() {
    final posts = socialActivity.feed(_channel);
    return _list([
      Container(
        padding: const EdgeInsets.all(24),
        color: _accent.withValues(alpha: .12),
        child: Row(
          children: [
            const UserAvatar(size: 60),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                _self,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      ),
      if (socialActivity.error != null) _note(socialActivity.error!),
      if (posts.isEmpty) _note('还没有动态。点击右上角发布第一条动态。'),
      for (final post in posts) _postCard(post),
      _row('自动动态与评论设置', Icons.tune, () => widget.go('/settings/social')),
    ]);
  }

  Widget _postCard(Map<String, dynamic> post) {
    final author = post['author'] as String;
    final likes = (post['likes'] as List).whereType<String>().toList();
    final images = (post['images'] as List).whereType<String>().toList();
    final comments = (post['comments'] as List).whereType<Map>();
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Color(0xffeeeeee))),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _avatar(author),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _name(author),
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    color: Color(0xff526388),
                  ),
                ),
                if ((post['text'] as String).isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: SelectableText(post['text'] as String),
                  ),
                if (images.isNotEmpty) _photoGrid(images),
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 4,
                  children: [
                    Text(
                      post['time'] as String,
                      style: const TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                    TextButton.icon(
                      onPressed: () => _notice(
                        socialActivity.interact('like', post['id'] as String),
                      ),
                      icon: Icon(
                        likes.contains('self')
                            ? Icons.favorite
                            : Icons.favorite_border,
                        size: 17,
                      ),
                      label: Text(likes.contains('self') ? '取消赞' : '赞'),
                    ),
                    TextButton.icon(
                      onPressed: () => _comment(post['id'] as String),
                      icon: const Icon(Icons.chat_bubble_outline, size: 17),
                      label: const Text('评论'),
                    ),
                    if (author == 'self')
                      TextButton(
                        onPressed: () => _deletePost(post['id'] as String),
                        child: const Text('删除'),
                      ),
                  ],
                ),
                if (likes.isNotEmpty || comments.isNotEmpty)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    color: const Color(0xfff4f4f4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (likes.isNotEmpty)
                          Text(
                            '♡ ${likes.map(_name).join('、')}',
                            style: const TextStyle(color: Color(0xff526388)),
                          ),
                        for (final c in comments)
                          Padding(
                            padding: const EdgeInsets.only(top: 5),
                            child: Text(
                              '${c['name'] is String && (c['name'] as String).isNotEmpty ? c['name'] : _name(c['author'] as String)}：${c['text']}',
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _comment(String id) async {
    final text = await _input('评论', maxLength: 1000);
    if (text != null && mounted)
      _notice(socialActivity.interact('comment', id, text: text));
  }

  Future<void> _deletePost(String id) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('删除这条动态？'),
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
    if (yes == true && mounted) _notice(socialActivity.interact('delete', id));
  }

  Widget _photo(String data, {BoxFit fit = BoxFit.cover}) {
    if (!data.startsWith('data:')) {
      // Old prototype illustrations were saved by symbolic name, not as photos.
      const labels = {
        'coast': '海岸插画',
        'flowers': '花卉插画',
        'clouds': '云朵插画',
        'coffee': '咖啡插画',
        'mountain': '山景插画',
        'sunset': '日落插画',
      };
      return ColoredBox(
        color: const Color(0xffe4e9e7),
        child: Center(child: Text(labels[data] ?? '历史图片')),
      );
    }
    try {
      return Image.memory(
        base64Decode(data.split(',').last),
        fit: fit,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) =>
            const Center(child: Icon(Icons.broken_image_outlined)),
      );
    } catch (_) {
      return const Center(child: Icon(Icons.broken_image_outlined));
    }
  }

  Widget _photoGrid(List<String> images, {bool editable = false}) =>
      LayoutBuilder(
        builder: (context, constraints) {
          final side = ((constraints.maxWidth - 12) / 3).clamp(40.0, 160.0);
          return Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (var i = 0; i < images.length; i++)
                SizedBox(
                  width: side,
                  height: side,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      InkWell(
                        onTap: () => _viewPhoto(images[i]),
                        child: _photo(images[i]),
                      ),
                      if (editable)
                        Positioned(
                          top: 0,
                          right: 0,
                          child: IconButton(
                            tooltip: '移除第${i + 1}张图片',
                            style: IconButton.styleFrom(
                              backgroundColor: Colors.black54,
                              foregroundColor: Colors.white,
                              minimumSize: const Size(30, 30),
                              padding: EdgeInsets.zero,
                            ),
                            onPressed: _publishing || _draftLoading
                                ? null
                                : () {
                                    setState(() => _images.removeAt(i));
                                    _draftChanged();
                                  },
                            icon: const Icon(Icons.close, size: 18),
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          );
        },
      );

  Future<void> _viewPhoto(String data) => showDialog<void>(
    context: context,
    builder: (c) => Dialog.fullscreen(
      backgroundColor: Colors.black,
      child: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                child: Center(child: _photo(data, fit: BoxFit.contain)),
              ),
            ),
            Positioned(
              top: 0,
              right: 0,
              child: IconButton(
                tooltip: '关闭图片',
                color: Colors.white,
                onPressed: () => Navigator.pop(c),
                icon: const Icon(Icons.close),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _compose() => _list([
    Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _post,
            enabled: !_draftLoading && !_publishing,
            minLines: 5,
            maxLines: 12,
            maxLength: 3000,
            decoration: const InputDecoration(
              hintText: '这一刻的想法…',
              border: InputBorder.none,
            ),
          ),
          _photoGrid(_images, editable: true),
          if (_images.length < 9)
            Wrap(
              children: [
                TextButton.icon(
                  onPressed: _picking || _draftLoading || _publishing
                      ? null
                      : () => _pickPhoto(ImageSource.gallery),
                  icon: const Icon(Icons.photo_library_outlined),
                  label: const Text('从相册选择'),
                ),
                TextButton.icon(
                  onPressed: _picking || _draftLoading || _publishing
                      ? null
                      : () => _pickPhoto(ImageSource.camera),
                  icon: const Icon(Icons.camera_alt_outlined),
                  label: const Text('拍摄照片'),
                ),
              ],
            ),
          if (_picking || _draftLoading || _publishing)
            const LinearProgressIndicator(),
          const Text(
            '最多9张图片。动态保存在此设备，与原有动态数据共用。',
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
        ],
      ),
    ),
  ]);

  Future<void> _publish() async {
    if (_publishing || _draftLoading || _picking) return;
    if (_post.text.trim().isEmpty && _images.isEmpty) {
      _notice('请先填写动态内容。');
      return;
    }
    _draftTimer?.cancel();
    setState(() => _publishing = true);
    try {
      _publishAttempt ??= DateTime.now().microsecondsSinceEpoch;
      if (await _saveDraft() != null || !mounted) return;
      final alreadyPublished = socialActivity.feed(_channel).any((p) {
        final stamp = int.tryParse(
          (p['id'] as String).split('-').elementAtOrNull(1) ?? '',
        );
        return stamp != null &&
            stamp >= _publishAttempt! &&
            p['author'] == 'self' &&
            p['text'] == _post.text.trim() &&
            jsonEncode(p['images']) == jsonEncode(_images);
      });
      if (!alreadyPublished) {
        final error = socialActivity.publish(
          _channel,
          _post.text,
          List.of(_images),
        );
        if (error != null) {
          _notice(error);
          return;
        }
      }
      if (!await socialActivity.flush()) {
        _notice(socialActivity.error ?? '动态未能保存，草稿已保留。');
        return;
      }
      if (await socialPostDrafts.clear(_channel) != null) {
        _notice('动态已发表，草稿清理未完成，请重试。');
        return;
      }
      _draftPublished = true;
      _post.clear();
      _images.clear();
      if (mounted) widget.navigate('moments');
    } finally {
      if (mounted) setState(() => _publishing = false);
    }
  }

  Future<void> _pickPhoto(ImageSource source) async {
    setState(() => _picking = true);
    try {
      _draftTimer?.cancel();
      if (await _saveDraft() != null) return;
      final file = await mediaPickerSession.run(
        MediaDestination.socialPost,
        () => ImagePicker().pickImage(
          source: source,
          maxWidth: 1600,
          maxHeight: 1600,
          imageQuality: 85,
          requestFullMetadata: false,
        ),
      );
      if (file == null) return;
      if (await file.length() > 6 * 1024 * 1024)
        throw const FormatException('请选择6MB以内的图片。');
      final data = await normalizeSocialPhoto(await file.readAsBytes());
      if (mounted && _images.length < 9) {
        setState(() => _images.add(data));
        _publishAttempt = null;
        await _saveDraft();
      }
    } on FormatException catch (e) {
      _notice(e.message);
    } catch (_) {
      _notice('无法读取图片，请检查相册或相机权限后重试。');
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Widget _albums() {
    final images = [
      for (final post in socialActivity.feed(_channel))
        ...(post['images'] as List).whereType<String>(),
    ];
    if (images.isEmpty) return _list([_note('暂无动态照片。发表带图片的动态后会显示在这里。')]);
    return GridView.builder(
      key: PageStorageKey('social-albums-${widget.mode.name}'),
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 6,
        crossAxisSpacing: 6,
      ),
      itemCount: images.length,
      itemBuilder: (context, index) => InkWell(
        onTap: () => _viewPhoto(images[index]),
        child: _photo(images[index]),
      ),
    );
  }

  Widget _favorites() {
    final items = [
      for (final c in demo.conversations)
        for (final m in c.messages)
          if (m.bookmarked) (c, m),
    ];
    return _list([
      if (items.isEmpty) _note('暂无收藏。长按聊天消息可收藏。'),
      for (final item in items)
        Card(
          margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.$1.title,
                  style: const TextStyle(color: Colors.grey, fontSize: 12),
                ),
                const SizedBox(height: 8),
                if (item.$2.imageData != null)
                  SizedBox(height: 160, child: _photo(item.$2.imageData!)),
                SelectableText(item.$2.text),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () async {
                      item.$2.bookmarked = false;
                      demo.changed();
                      await demo.saveChats();
                      _notice(demo.storageError);
                    },
                    child: const Text('取消收藏'),
                  ),
                ),
              ],
            ),
          ),
        ),
    ]);
  }

  String _money(int cents) => (cents / 100).toStringAsFixed(2);
  Widget _wallet() => _list([
    Container(
      color: widget.page == 'services' ? _accent : Colors.white,
      padding: const EdgeInsets.symmetric(vertical: 34, horizontal: 20),
      child: Column(
        children: [
          Icon(
            Icons.account_balance_wallet_outlined,
            size: 48,
            color: widget.page == 'services' ? Colors.white : _accent,
          ),
          const SizedBox(height: 14),
          Text(
            '¥ ${_money(virtualWallet.balance)}',
            style: TextStyle(
              fontSize: 38,
              fontWeight: FontWeight.w500,
              color: widget.page == 'services' ? Colors.white : Colors.black87,
            ),
          ),
          Text(
            '角色互动虚拟零钱',
            style: TextStyle(
              color: widget.page == 'services' ? Colors.white70 : Colors.grey,
            ),
          ),
        ],
      ),
    ),
    if (virtualWallet.error != null) _note(virtualWallet.error!),
    if (widget.page == 'services')
      _row('钱包', Icons.wallet_outlined, () => widget.navigate('wallet')),
    _row(
      '零钱明细',
      Icons.receipt_long_outlined,
      () => widget.navigate('wallet-records'),
    ),
    _row('收付款', Icons.qr_code, () => widget.navigate('cashier')),
    _row('设置虚拟零钱', Icons.edit_outlined, () => _walletForm('set')),
    _note('仅用于本机角色互动，不涉及真实资金或支付服务。'),
  ]);

  Widget _records() {
    final entries = (virtualWallet.snapshot()['entries'] as List)
        .whereType<Map>();
    return _list([
      if (entries.isEmpty) _note('暂无收支记录'),
      for (final e in entries)
        ListTile(
          tileColor: Colors.white,
          title: Text(
            e['kind'] == 'set'
                ? '余额调整'
                : '${(e['cents'] as int) < 0 ? '付款给' : '收到'} ${_role(e['roleId'] as String? ?? '')?.name ?? e['roleName'] ?? '角色'}',
          ),
          subtitle: Text(
            '${(e['created'] as String? ?? '').replaceAll('T', ' ').split('.').first}${(e['note'] as String? ?? '').isEmpty ? '' : ' · ${e['note']}'}',
          ),
          trailing: Text(
            '${(e['cents'] as int) > 0 ? '+' : '−'}${_money((e['cents'] as int).abs())}',
            style: TextStyle(
              fontSize: 17,
              color: (e['cents'] as int) > 0 ? _accent : Colors.black87,
            ),
          ),
        ),
      _note('仅记录角色互动中的虚拟收支。'),
    ]);
  }

  Widget _cashier() => _list([
    Container(
      color: Colors.white,
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const UserAvatar(size: 60),
          const SizedBox(height: 12),
          Text('$_self的虚拟钱包码'),
          const SizedBox(height: 20),
          NativeSocialQr(data: 'skivu://virtual-wallet/${virtualWallet.id}'),
          const SizedBox(height: 16),
          SelectableText(
            'skivu://virtual-wallet/${virtualWallet.id}',
            textAlign: TextAlign.center,
          ),
          TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(
                ClipboardData(
                  text: 'skivu://virtual-wallet/${virtualWallet.id}',
                ),
              );
              _notice('虚拟钱包码已复制');
            },
            icon: const Icon(Icons.copy),
            label: const Text('复制钱包码'),
          ),
        ],
      ),
    ),
    _row('向角色付款', Icons.arrow_upward, () => _walletForm('pay')),
    _row('模拟角色收款', Icons.arrow_downward, () => _walletForm('receive')),
    _row(
      '零钱明细',
      Icons.receipt_long_outlined,
      () => widget.navigate('wallet-records'),
    ),
    _note('角色互动虚拟钱包，不连接支付网络。'),
  ]);

  Future<void> _walletForm(String operation) async {
    if (operation != 'set' && demo.personas.isEmpty) {
      _notice('请先创建一位角色。');
      return;
    }
    final amount = TextEditingController(
      text: operation == 'set' ? _money(virtualWallet.balance) : '',
    );
    final note = TextEditingController();
    var roleId = demo.personas.firstOrNull?.id;
    var busy = false;
    String? error;
    final requestId = 'native-wallet-${DateTime.now().microsecondsSinceEpoch}';
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheet) => StatefulBuilder(
        builder: (sheet, update) => SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            20,
            0,
            20,
            MediaQuery.viewInsetsOf(sheet).bottom + 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                operation == 'set'
                    ? '设置虚拟零钱'
                    : operation == 'pay'
                    ? '向角色付款'
                    : '模拟角色收款',
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (operation != 'set')
                DropdownButtonFormField<String>(
                  initialValue: roleId,
                  decoration: const InputDecoration(labelText: '角色'),
                  items: [
                    for (final p in demo.personas)
                      DropdownMenuItem(value: p.id, child: Text(p.name)),
                  ],
                  onChanged: busy ? null : (v) => update(() => roleId = v),
                ),
              TextField(
                controller: amount,
                enabled: !busy,
                maxLength: 9,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  labelText: '虚拟金额',
                  hintText: '0.00',
                ),
              ),
              TextField(
                controller: note,
                enabled: !busy,
                maxLength: 100,
                decoration: const InputDecoration(labelText: '备注（选填）'),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('仅在本机记录角色互动虚拟收支，不涉及真实资金。'),
              ),
              if (error != null)
                Text(error!, style: const TextStyle(color: Colors.red)),
              FilledButton(
                onPressed: busy
                    ? null
                    : () async {
                        final cents = parseSocialWalletAmount(amount.text);
                        if (cents == null || operation != 'set' && cents == 0) {
                          update(() => error = '请输入有效金额，最多两位小数');
                          return;
                        }
                        final role = roleId == null ? null : _role(roleId!);
                        if (operation != 'set' && role == null) {
                          update(() => error = '角色已不存在，请重新选择。');
                          return;
                        }
                        update(() {
                          busy = true;
                          error = null;
                        });
                        final failure = await virtualWallet.change(
                          requestId: requestId,
                          operation: operation,
                          cents: cents,
                          roleId: role?.id ?? '',
                          roleName: role?.name ?? '',
                          note: note.text.trim(),
                        );
                        if (!sheet.mounted) return;
                        if (failure == null) {
                          Navigator.pop(sheet);
                          _notice('虚拟钱包已保存');
                        } else {
                          update(() {
                            busy = false;
                            error = failure;
                          });
                        }
                      },
                child: Text(busy ? '保存中…' : '确认保存'),
              ),
            ],
          ),
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    amount.dispose();
    note.dispose();
  }

  Widget _profile() => _list([
    _row(
      '头像',
      Icons.account_circle_outlined,
      () => editUserAvatar(context),
      subtitle: '与原版共用',
    ),
    Container(
      color: Colors.white,
      padding: const EdgeInsets.all(20),
      child: Row(
        children: [
          const UserAvatar(size: 64),
          const SizedBox(width: 20),
          Expanded(child: Text(_self, style: const TextStyle(fontSize: 24))),
        ],
      ),
    ),
    _row(
      '编辑个人资料',
      Icons.edit_outlined,
      _editBaseProfile,
      subtitle: '称呼、身份与背景、偏好及交流边界',
    ),
    _row(
      '编辑社交资料',
      Icons.badge_outlined,
      _editSocialProfile,
      subtitle: '社交账号、个性签名、地区与个人状态',
    ),
    for (final field in demo.userCard.entries)
      if (field.value.trim().isNotEmpty)
        ListTile(
          tileColor: Colors.white,
          title: Text(field.key),
          subtitle: Text(field.value),
        ),
    _row('相册', Icons.photo_outlined, () => widget.navigate('albums')),
    _row('收藏', Icons.bookmark_outline, () => widget.navigate('favorites')),
    _row('服务', Icons.wallet_outlined, () => widget.navigate('services')),
    _row('设置', Icons.settings_outlined, () => widget.navigate('settings')),
  ]);

  Widget _calls() {
    final calls =
        [
          for (final c in demo.conversations)
            for (final a in c.interactions)
              if (a['kind'] == 'call' &&
                  !c.hiddenInteractions.contains(a['id']))
                (c, a),
        ]..sort(
          (a, b) =>
              (b.$2['created'] as String).compareTo(a.$2['created'] as String),
        );
    return _list([
      _row('发起语音通话', Icons.call_outlined, () => widget.go('/call')),
      const ListTile(
        leading: Icon(Icons.videocam_outlined, color: Colors.grey),
        title: Text('视频通话', style: TextStyle(color: Colors.grey)),
        subtitle: Text('开发中'),
        enabled: false,
      ),
      if (calls.isEmpty) _note('暂无通话记录'),
      for (final call in calls)
        ListTile(
          tileColor: Colors.white,
          leading: Icon(
            (call.$2['payload'] as Map)['video'] == true
                ? Icons.videocam_outlined
                : Icons.call_outlined,
          ),
          title: Text(call.$1.title),
          subtitle: Text(
            '${(call.$2['created'] as String).replaceAll('T', ' ').split('.').first} · ${(call.$2['payload'] as Map)['duration']}秒',
          ),
        ),
    ]);
  }

  Widget _settings() => _list([
    _row('个人资料', Icons.person_outline, _editBaseProfile),
    _row('社交资料', Icons.badge_outlined, _editSocialProfile),
    _row('社交与自动互动', Icons.forum_outlined, () => widget.go('/settings/social')),
    _row(
      '外观设置',
      Icons.palette_outlined,
      () => widget.go('/settings/appearance'),
    ),
    _row('全部设置', Icons.settings_outlined, () => widget.go('/settings')),
    _migrationStatus(),
  ]);

  Future<void> _editBaseProfile() => editUserCard(context);

  Future<void> _editSocialProfile() async {
    const limits = {'社交账号': 36, '个性签名': 100, '地区': 30, '个人状态': 100};
    final fields = {
      for (final key in limits.keys)
        key: TextEditingController(text: demo.userCard[key] ?? ''),
    };
    var busy = false;
    String? error;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheet) => StatefulBuilder(
        builder: (sheet, update) => SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            20,
            0,
            20,
            MediaQuery.viewInsetsOf(sheet).bottom + 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '编辑社交资料',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
              ),
              for (final field in fields.entries)
                TextField(
                  controller: field.value,
                  enabled: !busy,
                  maxLength: limits[field.key],
                  maxLines: field.key == '个性签名' ? 3 : 1,
                  decoration: InputDecoration(labelText: field.key),
                ),
              if (error != null)
                Text(error!, style: const TextStyle(color: Colors.red)),
              FilledButton(
                onPressed: busy
                    ? null
                    : () async {
                        update(() => busy = true);
                        demo.userCard = {
                          ...demo.userCard,
                          for (final field in fields.entries)
                            field.key: field.value.text.trim(),
                        };
                        demo.changed();
                        await demo.saveChats();
                        if (!sheet.mounted) return;
                        if (demo.storageError == null) {
                          Navigator.pop(sheet);
                        } else {
                          update(() {
                            error = demo.storageError;
                            busy = false;
                          });
                        }
                      },
                child: const Text('保存社交资料'),
              ),
            ],
          ),
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    for (final field in fields.values) {
      field.dispose();
    }
  }

  Widget _migrationStatus() {
    final migration = legacySocialMigration;
    final status = switch (migration.status) {
      LegacySocialStatus.idle => '尚未检查旧社交资料',
      LegacySocialStatus.reading => '正在迁移旧社交资料…',
      LegacySocialStatus.complete => '旧社交资料迁移已完成，原始备份已保留',
      LegacySocialStatus.awaitingMode => '请在微信或QQ模式继续迁移动态',
      LegacySocialStatus.unsupported => '当前平台没有可读取的旧社交资料',
      LegacySocialStatus.failed => migration.error ?? '旧社交资料尚未完成迁移，可重试',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _note('旧版社交资料与备份'),
        ListTile(
          tileColor: Colors.white,
          leading: const Icon(Icons.archive_outlined),
          title: Text(status),
        ),
        if (migration.status != LegacySocialStatus.reading &&
            migration.status != LegacySocialStatus.complete &&
            migration.status != LegacySocialStatus.unsupported)
          _row('重新检查并迁移', Icons.refresh, () async {
            await migration.ensure(widget.mode);
          }),
        if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android)
          _row('导出旧社交原始JSON备份', Icons.save_alt, () async {
            try {
              final saved = await migration.saveBackupFile();
              if (saved) _notice('原始JSON备份已导出');
            } catch (_) {
              _notice('备份导出未完成，原始记录仍保留在本机。');
            }
          }),
      ],
    );
  }

  Widget _scan() => _list([
    _note('识别本机已有的 Skivu 角色码和虚拟钱包码。'),
    if (_picking) const LinearProgressIndicator(),
    _row('从相册识别二维码', Icons.photo_library_outlined, () {
      if (!_picking) _scanPhoto(ImageSource.gallery);
    }),
    _row('拍照识别二维码', Icons.camera_alt_outlined, () {
      if (!_picking) _scanPhoto(ImageSource.camera);
    }),
    _row('输入Skivu码内容', Icons.keyboard_outlined, () async {
      final text = await _input('输入Skivu码内容', maxLength: 500);
      if (text == null || !mounted) return;
      _openCode(text);
    }),
    _note('支持5MB以内的PNG、JPG或WebP图片，只识别本机Skivu码，不会打开外部链接。'),
  ]);

  void _openCode(String text) {
    final code = parseSocialCode(
      text,
      roleIds: demo.personas.map((p) => p.id).toSet(),
      walletId: virtualWallet.id,
    );
    if (code == null) {
      _notice('此二维码未对应本机角色或虚拟钱包。');
      return;
    }
    if (code.$1 == 'virtual-wallet') {
      widget.navigate('cashier');
      return;
    }
    if (widget.onRole != null) {
      widget.onRole!(code.$2);
      return;
    }
    final role = _role(code.$2);
    if (role != null) {
      demo.persona = demo.personas.indexOf(role);
      widget.go('/characters/edit');
    }
  }

  Future<void> _scanPhoto(ImageSource source) async {
    setState(() => _picking = true);
    try {
      final file = await mediaPickerSession.run(
        MediaDestination.socialScan,
        () =>
            ImagePicker().pickImage(source: source, requestFullMetadata: false),
      );
      if (file == null) return;
      if (await file.length() > 5 * 1024 * 1024)
        throw const FormatException('请选择5MB以内的图片。');
      final text = await compute(decodeSocialQrImage, await file.readAsBytes());
      if (mounted) _openCode(text);
    } on FormatException catch (e) {
      _notice(e.message);
    } catch (_) {
      _notice('没有识别到二维码，请使用清晰、完整的图片。');
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<String?> _input(String title, {required int maxLength}) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          minLines: 1,
          maxLines: 5,
          maxLength: maxLength,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, controller.text),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    controller.dispose();
    return result;
  }
}

/// Matches the existing HTML wallet's decimal grammar and the store's bound.
int? parseSocialWalletAmount(String raw) {
  final text = raw.trim();
  if (!RegExp(r'^(0|[1-9]\d{0,5})(\.\d{1,2})?$').hasMatch(text)) return null;
  final parts = text.split('.');
  return int.parse(parts.first) * 100 +
      int.parse((parts.length == 1 ? '' : parts.last).padRight(2, '0'));
}

/// Restrict both manual entry and decoded images to identifiers on this device.
(String, String)? parseSocialCode(
  String raw, {
  required Set<String> roleIds,
  required String walletId,
}) {
  if (raw.length > 500) return null;
  try {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null ||
        uri.scheme != 'skivu' ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.hasPort ||
        uri.userInfo.isNotEmpty ||
        uri.pathSegments.length != 1 ||
        !uri.path.startsWith('/'))
      return null;
    final id = uri.pathSegments.single;
    if (uri.host == 'role' && roleIds.contains(id)) return ('role', id);
    if (uri.host == 'virtual-wallet' && id == walletId)
      return ('virtual-wallet', id);
  } on FormatException {
    return null;
  }
  return null;
}

/// Called through compute so decoding never blocks the native input/scroll loop.
String decodeSocialQrImage(Uint8List bytes) {
  try {
    return _decodeSocialQrImage(bytes);
  } on FormatException {
    rethrow;
  } catch (_) {
    throw const FormatException('没有识别到二维码，请使用清晰、完整的图片。');
  }
}

String _decodeSocialQrImage(Uint8List bytes) {
  if (bytes.isEmpty || bytes.length > 5 * 1024 * 1024)
    throw const FormatException('请选择5MB以内的图片。');
  final decoder = img.findDecoderForData(bytes);
  if (decoder == null ||
      ![
        img.ImageFormat.png,
        img.ImageFormat.jpg,
        img.ImageFormat.webp,
      ].contains(decoder.format))
    throw const FormatException('请选择PNG、JPG或WebP图片。');
  final info = decoder.startDecode(bytes);
  if (info == null ||
      info.width <= 0 ||
      info.height <= 0 ||
      info.width > 8192 ||
      info.height > 8192)
    throw const FormatException('图片尺寸过大或无法读取。');
  var image = decoder.decodeFrame(0);
  if (image == null) throw const FormatException('无法读取图片。');
  image = img.bakeOrientation(image);
  if (image.width > 1600 || image.height > 1600)
    image = img.copyResize(
      image,
      width: image.width >= image.height ? 1600 : null,
      height: image.height > image.width ? 1600 : null,
    );
  final pixels = Int32List(image.width * image.height);
  for (final p in image) {
    final alpha = p.a / p.maxChannelValue;
    final r = (p.r * alpha + 255 * (1 - alpha)).round();
    final g = (p.g * alpha + 255 * (1 - alpha)).round();
    final b = (p.b * alpha + 255 * (1 - alpha)).round();
    pixels[p.y * image.width + p.x] = (r << 16) | (g << 8) | b;
  }
  final bitmap = zx.BinaryBitmap(
    zx.HybridBinarizer(
      zx.RGBLuminanceSource(image.width, image.height, pixels),
    ),
  );
  final text = zx.QRCodeReader().decode(bitmap).text;
  if (text.length > 500) throw const FormatException('二维码内容超出长度限制。');
  return text;
}

/// Four-module quiet zone and whole-pixel modules keep the generated QR readable.
class NativeSocialQr extends StatelessWidget {
  const NativeSocialQr({super.key, required this.data});
  final String data;
  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Skivu二维码',
    image: true,
    child: SizedBox.square(
      dimension: 220,
      child: CustomPaint(painter: SocialQrPainter(data)),
    ),
  );
}

class SocialQrPainter extends CustomPainter {
  SocialQrPainter(this.data)
    : matrix = qr.QrImage(
        qr.QrCode.fromData(
          data: data,
          errorCorrectLevel: qr.QrErrorCorrectLevel.M,
        ),
      );
  final String data;
  final qr.QrImage matrix;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    final count = matrix.moduleCount;
    final step = (size.shortestSide / (count + 8)).floorToDouble();
    final origin = Offset(
      (size.width - step * count) / 2,
      (size.height - step * count) / 2,
    );
    final paint = Paint()
      ..color = Colors.black
      ..isAntiAlias = false;
    for (var row = 0; row < count; row++) {
      for (var col = 0; col < count; col++) {
        if (matrix.isDark(row, col))
          canvas.drawRect(
            Rect.fromLTWH(
              origin.dx + col * step,
              origin.dy + row * step,
              step,
              step,
            ),
            paint,
          );
      }
    }
  }

  @override
  bool shouldRepaint(SocialQrPainter oldDelegate) => oldDelegate.data != data;
}

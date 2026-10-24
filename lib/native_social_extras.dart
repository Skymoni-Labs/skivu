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
import 'native_social_icons.dart';
import 'native_social_extra_components.dart';
import 'native_social_media_preview.dart';
import 'native_social_finance.dart';
import 'native_social_local_options.dart';
import 'native_social_portrait.dart';
import 'appearance.dart' as style;
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
    this.draftStore,
    this.previewRole,
  });

  final String page;
  final ChatUiMode mode;
  final ValueChanged<String> navigate, go;
  final VoidCallback onBack;
  final ValueChanged<String>? onRole;
  final SocialPostDraftStore? draftStore;
  final Persona? previewRole;

  @override
  State<NativeSocialExtras> createState() => _NativeSocialExtrasState();
}

class _NativeSocialExtrasState extends State<NativeSocialExtras> {
  SocialPostDraftStore get _drafts => widget.draftStore ?? socialPostDrafts;
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
  final _momentsScroll = ScrollController();
  bool _momentsScrolled = false;
  String? _postMenu;
  String get _channel => widget.mode == ChatUiMode.qq ? 'qq' : 'wx';
  Color get _accent => widget.mode == ChatUiMode.qq
      ? const Color(0xff0099ed)
      : const Color(0xff07a960);
  String get _self => demo.userCard['称呼']?.trim().isNotEmpty == true
      ? demo.userCard['称呼']!
      : '我';
  String get _signature => demo.userCard.containsKey('个性签名')
      ? demo.userCard['个性签名']!
      : '生活很慢，喜欢的事要慢慢来。';
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
    'me' => widget.mode == ChatUiMode.qq ? '个人主页' : '我',
    'profile' => '编辑个人资料',
    'calls' => '通话记录',
    'call-preview' => '语音通话',
    'settings' => '设置',
    'cards' || 'card' => '卡包',
    'status' => '设置状态',
    'miniapps' => '小程序',
    'files' => '文件',
    'privacy' => '可见范围',
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
    _momentsScroll.addListener(() {
      final next = _momentsScroll.offset > 130;
      if (next != _momentsScrolled && mounted)
        setState(() => _momentsScrolled = next);
    });
    unawaited(_restoreLocalPreferences());
    nativeSocialLocalOptions.addListener(_refresh);
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
          _drafts.save(
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
      final draft = await _drafts.read(channel);
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
    final failure = await _drafts.save(
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
        _drafts.save(
          _channel,
          _post.text,
          List.of(_images),
          publishAttempt: _publishAttempt,
        ),
      );
    _post.removeListener(_draftChanged);
    _post.dispose();
    _momentsScroll.dispose();
    nativeSocialLocalOptions.removeListener(_refresh);
    super.dispose();
  }

  void _notice(String? text) {
    if (text != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final moments = widget.page == 'moments', qq = widget.mode == ChatUiMode.qq;
    final transparent = moments && !qq && !_momentsScrolled;
    final background = moments
        ? (qq ? const Color(0xfff2f7fb) : Colors.white)
        : widget.page == 'wallet-records' ||
              qq &&
                  const {
                    'albums',
                    'favorites',
                    'files',
                    'miniapps',
                    'services',
                  }.contains(widget.page)
        ? Colors.white
        : const Color(0xffededed);
    return Material(
      color: background,
      child: DefaultTextStyle(
        style: const TextStyle(
          color: Color(0xff191919),
          fontSize: 16,
          fontFamily: 'SkiSans',
        ),
        child: SafeArea(
          top: !moments,
          child: moments
              ? Stack(
                  children: [
                    Positioned.fill(child: _body()),
                    Positioned(
                      top: MediaQuery.paddingOf(context).top,
                      left: 0,
                      right: 0,
                      child: _header(transparent: transparent),
                    ),
                  ],
                )
              : Column(
                  children: [
                    _header(),
                    Expanded(child: _body()),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _header({bool transparent = false}) {
    final qq = widget.mode == ChatUiMode.qq;
    return Container(
      key: const ValueKey('social-extra-header'),
      height: 52,
      width: double.infinity,
      color: transparent
          ? Colors.transparent
          : qq
          ? const Color(0xfff1f1f1)
          : const Color(0xffededed),
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (!transparent)
            Positioned(
              left: qq ? 52 : 62,
              right: 62,
              top: 0,
              bottom: 0,
              child: Align(
                alignment: qq ? Alignment.centerLeft : Alignment.center,
                child: Text(
                  _title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
          Positioned(
            left: 8,
            top: 4,
            bottom: 4,
            child: _iconAction(
              '返回',
              'interaction-back',
              widget.onBack,
              color: transparent ? Colors.white : null,
            ),
          ),
          Positioned(
            right: 8,
            top: 4,
            bottom: 4,
            child: widget.page == 'moments'
                ? _iconAction(
                    '发表动态',
                    'camera',
                    () => widget.navigate('compose'),
                    color: transparent ? Colors.white : null,
                  )
                : widget.page == 'wallet'
                ? _iconAction('更多钱包功能', 'more', _walletActions)
                : const SizedBox(width: 40),
          ),
        ],
      ),
    );
  }

  Widget _iconAction(
    String label,
    String icon,
    VoidCallback? action, {
    Color? color,
    double size = 24,
  }) => Semantics(
    label: label,
    button: true,
    enabled: action != null,
    child: InkWell(
      onTap: action,
      child: SizedBox(
        width: 40,
        height: 44,
        child: Center(
          child: NativeSocialIcon(
            icon,
            size: size,
            color: color ?? const Color(0xff191919),
          ),
        ),
      ),
    ),
  );
  Widget _group(List<Widget> children) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Column(children: children),
  );
  Widget _list(List<Widget> children, {bool moments = false}) => ListView(
    key: PageStorageKey('social-extra-${widget.mode.name}-${widget.page}'),
    controller: moments ? _momentsScroll : null,
    padding: const EdgeInsets.only(bottom: 24),
    keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
    children: children,
  );
  Widget _note(String text) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 17),
    child: Text(
      text,
      style: const TextStyle(
        color: Color(0xff818181),
        fontSize: 12,
        height: 1.65,
      ),
    ),
  );
  Widget _empty(String text) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 25, vertical: 35),
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: const TextStyle(
        fontSize: 14,
        height: 1.8,
        color: Color(0xff888888),
      ),
    ),
  );
  Widget _featureNote(String text) => Padding(
    padding: const EdgeInsets.all(18),
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: const TextStyle(
        fontSize: 12,
        height: 1.6,
        color: Color(0xff7c8187),
      ),
    ),
  );
  Widget _section(String text) => Container(
    color: const Color(0xffededed),
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
    child: Text(
      text,
      style: const TextStyle(fontSize: 12, color: Color(0xff888888)),
    ),
  );
  String _iconName(IconData icon) => switch (icon) {
    Icons.wallet_outlined || Icons.account_balance_wallet_outlined => 'wallet',
    Icons.settings_outlined || Icons.tune => 'settings',
    Icons.person_outline || Icons.account_circle_outlined => 'user',
    Icons.badge_outlined => 'user',
    Icons.photo_outlined || Icons.photo_library_outlined => 'image',
    Icons.bookmark_outline => 'box',
    Icons.receipt_long_outlined => 'list',
    Icons.qr_code => 'qr',
    Icons.call_outlined => 'phone',
    Icons.camera_alt_outlined => 'camera',
    Icons.palette_outlined => 'sliders',
    Icons.keyboard_outlined => 'keyboard',
    Icons.edit_outlined => 'sliders',
    Icons.save_alt => 'arrow-up',
    Icons.refresh => 'history',
    Icons.forum_outlined => 'chat',
    _ => 'right',
  };
  Widget _row(
    String text,
    IconData icon,
    VoidCallback action, {
    String? subtitle,
  }) => SocialExtraMenuRow(
    label: text,
    icon: _iconName(icon),
    note: subtitle,
    onTap: action,
  );
  Widget _menu(
    String text,
    String? icon,
    VoidCallback action, {
    String? note,
    Color color = const Color(0xff586e91),
  }) => SocialExtraMenuRow(
    label: text,
    icon: icon,
    note: note,
    color: color,
    onTap: action,
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
    'me' => _profile(),
    'profile' => SocialNativeProfileForm(
      mode: widget.mode,
      onDone: widget.onBack,
      onAvatar: _editAvatar,
    ),
    'calls' => _calls(),
    'call-preview' => SocialNativeCallPreview(
      mode: widget.mode,
      role: widget.previewRole,
      onHangUp: widget.onBack,
    ),
    'settings' => _settings(),
    'cards' || 'card' => _list([
      _note('卡包入口为本机页面预览，未连接真实平台服务。'),
      _menu('收付款', 'qr', () => widget.navigate('cashier')),
      _menu('虚拟钱包', 'wallet', () => widget.navigate('wallet')),
    ]),
    'status' => _statusPage(),
    'miniapps' => _miniapps(),
    'files' => _files(),
    'privacy' => _list([
      _note('当前内容仅保存在此设备，不同步到真实社交平台。'),
      _menu('朋友可见', 'users', () => _notice('本机角色动态，不向真实社交平台发布。')),
    ]),
    _ => _list([
      _note('此入口为本机页面预览，未连接真实平台服务。'),
      _menu('回到原版工作区', 'cloud', () => _classic()),
    ]),
  };

  Persona? _role(String id) =>
      demo.personas.where((p) => p.id == id).firstOrNull;
  String _name(String id) => id == 'self' ? _self : _role(id)?.name ?? '已移除的角色';
  Widget _avatar(String id) => NativeSocialPortrait(
    mode: widget.mode,
    user: id == 'self',
    persona: id == 'self' ? null : _role(id),
    size: 40,
  );

  Widget _moments() {
    final posts = socialActivity.feed(_channel);
    final qq = widget.mode == ChatUiMode.qq;
    return _list([
      SizedBox(
        height: (qq ? 266 : 286) + (qq ? 25 : 56),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: qq ? 266 : 286,
              child: const SocialExtraArt('coast'),
            ),
            Positioned(
              bottom: qq ? 45 : 76,
              left: qq ? 110 : null,
              right: qq ? 20 : 109,
              child: Text(
                _self,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                  shadows: [Shadow(color: Color(0x80253e4d), blurRadius: 4)],
                ),
              ),
            ),
            Positioned(
              left: qq ? 20 : null,
              right: qq ? null : 17,
              bottom: qq ? 3 : 29,
              child: Semantics(
                button: true,
                label: '我的主页',
                child: GestureDetector(
                  onTap: () => widget.navigate('me'),
                  child: Container(
                    width: 76,
                    height: 76,
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(
                        style.appearance.flag('squareAvatars')
                            ? 0
                            : qq
                            ? 38
                            : 7,
                      ),
                    ),
                    child: NativeSocialPortrait(
                      mode: widget.mode,
                      user: true,
                      size: 70,
                      large: true,
                      borderRadius: qq ? 35 : 4,
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              bottom: qq ? 0 : 3,
              left: qq ? 110 : 16,
              right: 17,
              child: Text(
                _signature,
                maxLines: 1,
                textAlign: qq ? TextAlign.left : TextAlign.right,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: Color(0xff888888)),
              ),
            ),
          ],
        ),
      ),
      if (qq)
        Container(
          color: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 15, horizontal: 20),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _stat(
                '${posts.fold<int>(0, (n, p) => n + (p['images'] as List).length)}',
                '相册',
                () => widget.navigate('albums'),
              ),
              _stat(
                '${posts.where((p) => p['author'] == 'self').length}',
                '说说',
                () => widget.navigate('compose'),
              ),
              _stat('—', '访客', () => _explain('最近访客', '本机角色动态没有联网访客统计。')),
            ],
          ),
        ),
      if (socialActivity.error != null) _note(socialActivity.error!),
      for (final post in posts) _postCard(post),
      const Padding(
        padding: EdgeInsets.all(20),
        child: Text(
          '已经看到这里啦',
          textAlign: TextAlign.center,
          style: TextStyle(color: Color(0xff9da6ab), fontSize: 12),
        ),
      ),
    ], moments: true);
  }

  Widget _stat(String value, String label, VoidCallback onTap) => InkWell(
    onTap: onTap,
    child: Column(
      children: [
        Text(
          value,
          style: const TextStyle(
            fontSize: 15,
            color: Color(0xff47657a),
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: const TextStyle(fontSize: 13, color: Color(0xff8b9fab)),
        ),
      ],
    ),
  );

  Widget _postCard(Map<String, dynamic> post) {
    final author = post['author'] as String, id = post['id'] as String;
    final likes = (post['likes'] as List).whereType<String>().toList();
    final images = (post['images'] as List).whereType<String>().toList();
    final comments = (post['comments'] as List).whereType<Map>();
    final qq = widget.mode == ChatUiMode.qq;
    void profile() {
      if (author == 'self') {
        widget.navigate('me');
      } else {
        widget.onRole?.call(author);
      }
    }

    Widget actions({bool popup = false}) => Container(
      height: 35,
      decoration: popup
          ? BoxDecoration(
              color: const Color(0xff4c5154),
              borderRadius: BorderRadius.circular(5),
            )
          : null,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final action in ['like', 'comment'])
            InkWell(
              onTap: () {
                setState(() => _postMenu = null);
                if (action == 'like') {
                  _notice(socialActivity.interact('like', id));
                } else {
                  _comment(id);
                }
              },
              child: Container(
                constraints: BoxConstraints(minWidth: popup ? 75 : 48),
                padding: const EdgeInsets.symmetric(horizontal: 5),
                decoration: action == 'comment' && popup
                    ? const BoxDecoration(
                        border: Border(
                          left: BorderSide(color: Color(0xff626568)),
                        ),
                      )
                    : null,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    NativeSocialIcon(
                      action == 'like' ? 'heart' : 'chat',
                      size: 15,
                      color: popup ? Colors.white : const Color(0xff617d9e),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      action == 'like'
                          ? (likes.contains('self') ? '取消赞' : '赞')
                          : '评论',
                      style: TextStyle(
                        fontSize: 13,
                        color: popup ? Colors.white : const Color(0xff617d9e),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
    return Container(
      margin: qq ? const EdgeInsets.symmetric(vertical: 8) : EdgeInsets.zero,
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 18),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Color(0xffeff0f2))),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: profile,
            child: SizedBox.square(dimension: 40, child: _avatar(author)),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                GestureDetector(
                  onTap: profile,
                  child: Text(
                    _name(author),
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      height: 1.25,
                      color: Color(0xff576b95),
                    ),
                  ),
                ),
                const SizedBox(height: 5),
                if ((post['text'] as String).isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 9),
                    child: SelectableText(
                      post['text'] as String,
                      style: const TextStyle(fontSize: 16, height: 1.5),
                    ),
                  ),
                if (images.isNotEmpty)
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: images.length == 1 ? 180 : 280,
                    ),
                    child: images.length == 1
                        ? AspectRatio(
                            aspectRatio: 1.18,
                            child: GestureDetector(
                              onTap: () => _viewPhoto(images.first),
                              child: _photo(images.first),
                            ),
                          )
                        : _photoGrid(images),
                  ),
                const SizedBox(height: 9),
                SizedBox(
                  height: 28,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              post['time'] as String,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Color(0xffaaaaaa),
                                fontSize: 12,
                              ),
                            ),
                          ),
                          if (author == 'self') ...[
                            const SizedBox(width: 10),
                            GestureDetector(
                              onTap: () => _deletePost(id),
                              child: const Text(
                                '删除',
                                style: TextStyle(
                                  color: Color(0xff576b95),
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ],
                          const SizedBox(width: 8),
                          if (qq)
                            actions()
                          else
                            Semantics(
                              button: true,
                              label: '动态操作',
                              child: GestureDetector(
                                onTap: () => setState(
                                  () => _postMenu = _postMenu == id ? null : id,
                                ),
                                child: Container(
                                  width: 30,
                                  height: 21,
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: const Color(0xfff0f1f3),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: const NativeSocialIcon(
                                    'more',
                                    size: 20,
                                    color: Color(0xff576b95),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                      if (!qq && _postMenu == id)
                        Positioned(
                          right: 39,
                          top: -7,
                          child: actions(popup: true),
                        ),
                    ],
                  ),
                ),
                if (likes.isNotEmpty || comments.isNotEmpty)
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(top: 5),
                    decoration: BoxDecoration(
                      color: const Color(0xfff3f3f5),
                      borderRadius: BorderRadius.circular(2),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (likes.isNotEmpty)
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(7),
                            decoration: const BoxDecoration(
                              border: Border(
                                bottom: BorderSide(color: Color(0xffe5e5e5)),
                              ),
                            ),
                            child: Text(
                              '♡ ${likes.map(_name).join('、')}',
                              style: const TextStyle(
                                color: Color(0xff576b95),
                                fontSize: 14,
                                height: 1.5,
                              ),
                            ),
                          ),
                        for (final c in comments)
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 3,
                            ),
                            child: Text.rich(
                              TextSpan(
                                children: [
                                  TextSpan(
                                    text:
                                        '${c['name'] is String && (c['name'] as String).isNotEmpty ? c['name'] : _name(c['author'] as String)}：',
                                    style: const TextStyle(
                                      color: Color(0xff576b95),
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  TextSpan(text: c['text'] as String),
                                ],
                              ),
                              style: const TextStyle(
                                fontSize: 14,
                                height: 1.55,
                              ),
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

  Future<void> _deletePost(String id) => _showPage<void>(
    '删除这条动态？',
    (page) => _list([
      _menu('确认删除本地动态', null, () {
        _notice(socialActivity.interact('delete', id));
        Navigator.pop(page);
      }),
      _menu('取消', null, () => Navigator.pop(page)),
    ]),
  );

  Widget _photo(String data, {BoxFit fit = BoxFit.cover}) {
    if (!data.startsWith('data:')) return SocialExtraArt(data);
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

  Widget _photoGrid(List<String> images) => LayoutBuilder(
    builder: (context, constraints) {
      final side = ((constraints.maxWidth - 8) / 3).clamp(40.0, 160.0);
      return Wrap(
        spacing: 4,
        runSpacing: 4,
        children: [
          for (final image in images)
            SizedBox.square(
              dimension: side,
              child: GestureDetector(
                onTap: () => _viewPhoto(image),
                child: _photo(image),
              ),
            ),
        ],
      );
    },
  );

  Future<void> _viewPhoto(String data) => _showPage<void>(
    '生活碎片',
    (_) => InteractiveViewer(
      child: Center(
        child: AspectRatio(
          aspectRatio: 1,
          child: _photo(data, fit: BoxFit.contain),
        ),
      ),
    ),
  );

  Widget _compose() => ColoredBox(
    color: Colors.white,
    child: _list([
      Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                NativeSocialPortrait(mode: widget.mode, user: true, size: 44),
                const SizedBox(width: 10),
                Text(_self, style: const TextStyle(fontSize: 16)),
              ],
            ),
            const SizedBox(height: 17),
            TextField(
              controller: _post,
              enabled: !_draftLoading && !_publishing,
              minLines: 1,
              maxLines: 3,
              maxLength: 3000,
              style: const TextStyle(fontSize: 16, height: 1.5),
              decoration: const InputDecoration(
                hintText: '这一刻的想法…',
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 9,
                  vertical: 9,
                ),
                counterText: '',
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 13, bottom: 22),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (var i = 0; i < _images.length; i++)
                    SizedBox.square(
                      dimension: 80,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          _photo(_images[i]),
                          Positioned(
                            top: 0,
                            right: 0,
                            child: Semantics(
                              label: '移除第${i + 1}张图片',
                              button: true,
                              child: GestureDetector(
                                onTap: _publishing
                                    ? null
                                    : () {
                                        setState(() => _images.removeAt(i));
                                        _draftChanged();
                                      },
                                child: Container(
                                  color: const Color(0x88284050),
                                  padding: const EdgeInsets.all(3),
                                  child: const NativeSocialIcon(
                                    'close',
                                    size: 14,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (_images.length < 9)
                    Semantics(
                      label: '添加动态图片',
                      button: true,
                      child: SocialExtraAddPhotoTile(
                        onTap: _picking || _draftLoading || _publishing
                            ? null
                            : _addPhotoMenu,
                      ),
                    ),
                ],
              ),
            ),
            _composeOption(
              '所在位置',
              'pin',
              '不显示位置',
              () => _explain(
                '所在位置',
                '位置示例：沿河步道。未读取设备位置。',
                illustration: const SizedBox(
                  height: 160,
                  child: Center(
                    child: NativeSocialIcon(
                      'pin',
                      size: 46,
                      color: Color(0xff86a6a3),
                    ),
                  ),
                ),
              ),
            ),
            _composeOption(
              '谁可以看',
              'users',
              '朋友可见',
              () => _explain('可见范围', '当前动态只保存在此设备，不同步到真实社交平台。'),
            ),
            if (_picking || _draftLoading || _publishing)
              const LinearProgressIndicator(),
            const SizedBox(height: 24),
            Align(
              alignment: Alignment.center,
              child: SizedBox(
                width: widget.mode == ChatUiMode.qq ? double.infinity : 180,
                child: SocialExtraButton(
                  label: _publishing ? '发表中…' : '发表',
                  onTap: _picking || _draftLoading || _publishing
                      ? null
                      : _publish,
                  color: _accent,
                ),
              ),
            ),
          ],
        ),
      ),
    ]),
  );
  Widget _composeOption(
    String label,
    String icon,
    String note,
    VoidCallback action,
  ) => SizedBox(
    width: 168,
    child: InkWell(
      onTap: action,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 13),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: Color(0xffedf0f2))),
        ),
        child: Row(
          children: [
            NativeSocialIcon(icon, size: 16, color: const Color(0xff587080)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(fontSize: 12, color: Color(0xff587080)),
              ),
            ),
            Text(
              note,
              style: const TextStyle(fontSize: 10, color: Color(0xffa0abb4)),
            ),
            const SizedBox(width: 8),
            const NativeSocialIcon('right', size: 16, color: Color(0xffa0abb4)),
          ],
        ),
      ),
    ),
  );

  Future<void> _addPhotoMenu() => _showPage<void>(
    '添加图片',
    (c) => _list([
      _menu('从相册选择', 'image', () {
        Navigator.pop(c);
        _pickPhoto(ImageSource.gallery);
      }),
      _menu('拍摄照片', 'camera', () {
        Navigator.pop(c);
        _pickPhoto(ImageSource.camera);
      }),
      _note('或选择内置插画'),
      Padding(
        padding: const EdgeInsets.all(16),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final name in [
              'coast',
              'flowers',
              'clouds',
              'coffee',
              'mountain',
              'sunset',
            ])
              Semantics(
                label: '选择内置插画$name',
                button: true,
                child: GestureDetector(
                  onTap: () async {
                    Navigator.pop(c);
                    final asset = await rootBundle.load(
                      'assets/social_native/$name.png',
                    );
                    final image = await normalizeSocialPhoto(
                      asset.buffer.asUint8List(
                        asset.offsetInBytes,
                        asset.lengthInBytes,
                      ),
                    );
                    if (mounted && _images.length < 9) {
                      setState(() => _images.add(image));
                      _publishAttempt = null;
                      await _saveDraft();
                    }
                  },
                  child: SizedBox.square(
                    dimension: 80,
                    child: SocialExtraArt(name),
                  ),
                ),
              ),
          ],
        ),
      ),
    ]),
  );

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
      if (await _drafts.clear(_channel) != null) {
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

  List<(Conversation, Map<String, dynamic>)> _attachments(Set<String> kinds) =>
      [
        for (final c in demo.conversations)
          for (final e in c.interactions)
            if (kinds.contains(e['kind']) &&
                !c.hiddenInteractions.contains(e['id']) &&
                (c.interactionsClearedAt == null ||
                    DateTime.tryParse(
                          e['created'] as String? ?? '',
                        )?.isAfter(c.interactionsClearedAt!) ==
                        true))
              (c, e),
      ]..sort(
        (a, b) =>
            (b.$2['created'] as String).compareTo(a.$2['created'] as String),
      );
  Widget _attachmentRow(Conversation chat, Map<String, dynamic> event) {
    final payload = event['payload'] as Map;
    return Material(
      color: Colors.white,
      child: InkWell(
        onTap: () => _showPage<void>(
          payload['name'] as String? ?? '附件',
          (_) => SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                NativeSocialMediaPreview(event: event, expanded: true),
                _note('来自${chat.title} · 本机聊天附件'),
              ],
            ),
          ),
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: Color(0xfff1f1f1))),
          ),
          child: Row(
            children: [
              NativeSocialIcon(
                event['kind'] == 'image'
                    ? 'image'
                    : event['kind'] == 'video'
                    ? 'video'
                    : event['kind'] == 'file'
                    ? 'folder'
                    : 'music',
                size: 28,
                color: const Color(0xffb2a17d),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      payload['name'] as String? ?? '附件',
                      style: const TextStyle(fontSize: 15),
                    ),
                    const SizedBox(height: 7),
                    Text(
                      '${_role(chat.personaId ?? '')?.name ?? chat.title} · ${(event['created'] as String).split('T').first}',
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xff999999),
                      ),
                    ),
                  ],
                ),
              ),
              const NativeSocialIcon(
                'right',
                size: 15,
                color: Color(0xffbbbbbb),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _albums() {
    final images = [
      for (final post in socialActivity.feed(_channel))
        ...(post['images'] as List).whereType<String>(),
    ];
    final attachments = _attachments({'image', 'video'});
    return CustomScrollView(
      key: PageStorageKey('social-albums-${widget.mode.name}'),
      slivers: [
        if (images.isNotEmpty)
          SliverToBoxAdapter(child: _section('生活碎片 · ${images.length} 张动态照片')),
        if (images.isNotEmpty)
          SliverPadding(
            padding: const EdgeInsets.all(3),
            sliver: SliverGrid(
              delegate: SliverChildBuilderDelegate(
                (context, index) => GestureDetector(
                  onTap: () => _viewPhoto(images[index]),
                  child: _photo(images[index]),
                ),
                childCount: images.length,
              ),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 3,
                crossAxisSpacing: 3,
              ),
            ),
          ),
        if (attachments.isNotEmpty)
          SliverToBoxAdapter(child: _note('聊天中的图片与视频')),
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) =>
                _attachmentRow(attachments[index].$1, attachments[index].$2),
            childCount: attachments.length,
          ),
        ),
        if (images.isEmpty && attachments.isEmpty)
          SliverToBoxAdapter(child: _empty('还没有图片或视频，可从聊天“＋”中添加。')),
        const SliverPadding(padding: EdgeInsets.only(bottom: 24)),
      ],
    );
  }

  Widget _files() {
    final items = _attachments({'file', 'music', 'audio'});
    return _list([
      if (items.isEmpty) _empty('还没有文件，可从聊天“＋”中添加。'),
      for (final item in items) _attachmentRow(item.$1, item.$2),
    ]);
  }

  Widget _favorites() {
    final items = [
      for (final c in demo.conversations)
        for (final m in c.messages)
          if (m.bookmarked) (c, m),
    ];
    return _list([
      if (items.isEmpty) _empty('暂无收藏，可从聊天消息菜单添加。'),
      for (final item in items)
        Material(
          color: Colors.white,
          child: InkWell(
            onTap: () => _showPage<void>(
              '收藏',
              (c) => SingleChildScrollView(
                padding: const EdgeInsets.all(17),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (item.$2.imageData != null)
                      SizedBox(height: 240, child: _photo(item.$2.imageData!)),
                    SelectableText(
                      item.$2.text,
                      style: const TextStyle(fontSize: 15, height: 1.7),
                    ),
                    _note('来自${item.$1.title}'),
                    _menu('取消收藏', 'box', () async {
                      item.$2.bookmarked = false;
                      demo.changed();
                      await demo.saveChats();
                      if (c.mounted) Navigator.pop(c);
                      _notice(demo.storageError);
                    }),
                  ],
                ),
              ),
            ),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: Color(0xfff1f1f1))),
              ),
              child: Text(
                item.$2.text,
                style: const TextStyle(fontSize: 15, height: 1.7),
              ),
            ),
          ),
        ),
    ]);
  }

  String _money(int cents) => (cents / 100).toStringAsFixed(2);
  Widget _wallet() {
    if (widget.page == 'services')
      return _list([
        Container(
          margin: const EdgeInsets.fromLTRB(10, 12, 10, 0),
          decoration: BoxDecoration(
            color: const Color(0xff07a86c),
            borderRadius: BorderRadius.circular(9),
          ),
          child: InkWell(
            onTap: () => widget.navigate('wallet'),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 29, horizontal: 15),
              child: Column(
                children: [
                  const NativeSocialIcon(
                    'wallet',
                    size: 32,
                    color: Colors.white,
                  ),
                  const SizedBox(height: 11),
                  const Text(
                    '钱包',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w500,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 11),
                  Text(
                    '¥ ${_money(virtualWallet.balance)}',
                    style: const TextStyle(fontSize: 14, color: Colors.white60),
                  ),
                ],
              ),
            ),
          ),
        ),
        _featureNote('角色互动虚拟钱包'),
      ]);
    return ColoredBox(
      color: Colors.white,
      child: _list([
        Container(
          color: Colors.white,
          padding: const EdgeInsets.fromLTRB(15, 38, 15, 34),
          child: Column(
            children: [
              const NativeSocialIcon(
                'wallet',
                size: 49,
                color: Color(0xffdbac4c),
              ),
              const SizedBox(height: 16),
              const Text('零钱', style: TextStyle(fontSize: 17)),
              const SizedBox(height: 15),
              Text(
                '¥ ${_money(virtualWallet.balance)}',
                style: const TextStyle(
                  fontSize: 39,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 11),
              const Text(
                '角色互动虚拟零钱',
                style: TextStyle(fontSize: 12, color: Color(0xff818181)),
              ),
            ],
          ),
        ),
        if (virtualWallet.error != null) _note(virtualWallet.error!),
        _menu('零钱明细', null, () => widget.navigate('wallet-records')),
        _menu('收付款', null, () => widget.navigate('cashier')),
        _menu('设置虚拟零钱', null, () => _walletForm('set')),
      ]),
    );
  }

  Future<void> _walletActions() => _showPage<void>(
    '钱包功能',
    (page) => _list([
      _menu('模拟角色转账', 'transfer', () {
        Navigator.pop(page);
        _openFinance('transfer', incoming: true);
      }),
      _menu('模拟角色红包', 'envelope', () {
        Navigator.pop(page);
        _openFinance('redpacket', incoming: true);
      }),
      _menu('向角色付款', 'transfer', () {
        Navigator.pop(page);
        _openFinance('transfer');
      }),
      _menu('账单', 'list', () {
        Navigator.pop(page);
        widget.navigate('wallet-records');
      }),
    ]),
  );

  Widget _records() {
    final entries = (virtualWallet.snapshot()['entries'] as List)
        .whereType<Map>();
    final transactions = (virtualWallet.snapshot()['transactions'] as List)
        .whereType<Map>();
    return _list([
      if (entries.isEmpty) _empty('暂无收支记录'),
      for (final e in entries)
        Material(
          color: Colors.white,
          child: InkWell(
            onTap: () {
              final t = transactions
                  .where((t) => t['id'] == e['transactionId'])
                  .firstOrNull;
              if (t != null)
                showNativeSocialReceipt(
                  context,
                  Map<String, dynamic>.from(t),
                  mode: widget.mode,
                  navigate: widget.navigate,
                  go: widget.go,
                );
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: Color(0xffeeeeee))),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${e['kind'] == 'set'
                              ? '余额调整'
                              : e['kind'] == 'refund'
                              ? '退回'
                              : e['kind'] == 'redpacket'
                              ? '红包'
                              : e['kind'] == 'gift'
                              ? '礼物'
                              : '转账'} ${e['roleName'] ?? ''}',
                          style: const TextStyle(fontSize: 15),
                        ),
                        const SizedBox(height: 7),
                        Text(
                          '${(e['created'] as String? ?? '').replaceAll('T', ' ').split('.').first}${(e['note'] as String? ?? '').isEmpty ? '' : ' · ${e['note']}'}',
                          style: const TextStyle(
                            fontSize: 11,
                            color: Color(0xff929292),
                            height: 1.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    '${(e['cents'] as int) > 0 ? '+' : '−'}${_money((e['cents'] as int).abs())}',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      _featureNote('仅记录角色互动中的虚拟收支'),
    ]);
  }

  Widget _cashier() => ColoredBox(
    color: const Color(0xffefbd4a),
    child: _list([
      Container(
        margin: const EdgeInsets.fromLTRB(16, 17, 16, 20),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 22),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          children: [
            const Text(
              '二维码收款',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 20),
            GestureDetector(
              onLongPress: () async {
                await Clipboard.setData(
                  ClipboardData(
                    text: 'skivu://virtual-wallet/${virtualWallet.id}',
                  ),
                );
                _notice('虚拟钱包码已复制');
              },
              child: NativeSocialQr(
                data: 'skivu://virtual-wallet/${virtualWallet.id}',
                size: 240,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              '$_self的虚拟收款码',
              style: const TextStyle(fontSize: 13, color: Color(0xff777777)),
            ),
          ],
        ),
      ),
      _menu('向角色付款', null, () => _openFinance('transfer')),
      _menu('模拟角色收款', null, () => _openFinance('transfer', incoming: true)),
      _menu('零钱明细', null, () => widget.navigate('wallet-records')),
      _featureNote('角色互动虚拟钱包'),
    ]),
  );

  Future<void> _openFinance(String kind, {bool incoming = false}) async {
    var chat = demo.conversations.elementAtOrNull(demo.conversation);
    if (chat == null ||
        chat.groupMembers.isNotEmpty ||
        _role(chat.personaId ?? '') == null) {
      final roleId = await _showPage<String>(
        '选择角色',
        (c) => _list([
          for (final role in demo.personas)
            _menu(role.name, 'user', () => Navigator.pop(c, role.id)),
          if (demo.personas.isEmpty) _note('请先在原版角色库创建角色。'),
        ]),
      );
      if (roleId == null || !mounted) return;
      final existing = demo.conversations.indexWhere(
        (c) => c.personaId == roleId && c.groupMembers.isEmpty,
      );
      if (existing >= 0) {
        demo.selectChat(existing);
      } else {
        demo.newChat(personaId: roleId);
      }
      chat = demo.conversations[demo.conversation];
    }
    if (!mounted) return;
    await showNativeSocialFinance(
      context,
      mode: widget.mode,
      kind: kind,
      incoming: incoming,
      navigate: widget.navigate,
      go: widget.go,
      onCreated: () {
        uiPlugins.showConversation();
        widget.navigate('chat');
      },
    );
  }

  Future<void> _walletForm(String operation) async {
    if (operation != 'set') {
      await _openFinance('transfer', incoming: operation == 'receive');
      return;
    }
    final amount = TextEditingController(text: _money(virtualWallet.balance));
    var busy = false;
    String? error;
    final requestId = 'native-wallet-${DateTime.now().microsecondsSinceEpoch}';
    await _showPage<void>(
      '设置虚拟零钱',
      (page) => StatefulBuilder(
        builder: (page, update) => ListView(
          padding: const EdgeInsets.all(18),
          children: [
            const Text(
              '零钱余额',
              style: TextStyle(fontSize: 13, color: Color(0xff637987)),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: amount,
              enabled: !busy,
              maxLength: 9,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                hintText: '0.00',
                labelText: '虚拟金额',
              ),
            ),
            _note('角色互动虚拟钱包 · 设置后保存在此设备，不涉及真实资金。'),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  error!,
                  style: const TextStyle(color: Colors.red, fontSize: 13),
                ),
              ),
            SocialExtraButton(
              label: busy ? '保存中…' : '保存余额',
              onTap: busy
                  ? null
                  : () async {
                      final cents = parseSocialWalletAmount(amount.text);
                      if (cents == null) {
                        update(() => error = '请输入有效金额，最多两位小数');
                        return;
                      }
                      update(() => busy = true);
                      final failure = await virtualWallet.change(
                        requestId: requestId,
                        operation: 'set',
                        cents: cents,
                      );
                      if (!page.mounted) return;
                      if (failure == null) {
                        Navigator.pop(page);
                        _notice('虚拟钱包已保存');
                      } else {
                        update(() {
                          busy = false;
                          error = failure;
                        });
                      }
                    },
              color: _accent,
            ),
          ],
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    amount.dispose();
  }

  Widget _profile() {
    final qq = widget.mode == ChatUiMode.qq;
    return _list([
      Material(
        color: Colors.white,
        child: InkWell(
          onTap: _editSocialProfile,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 34, 24, 30),
            child: Row(
              children: [
                NativeSocialPortrait(
                  mode: widget.mode,
                  user: true,
                  size: 64,
                  large: true,
                  borderRadius: 7,
                ),
                const SizedBox(width: 18),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _self,
                        style: const TextStyle(
                          fontSize: 23,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 9),
                      Text(
                        '${qq ? 'QQ号' : '微信号'}：${demo.userCard['社交账号'] ?? ''}',
                        style: const TextStyle(
                          fontSize: 13,
                          color: Color(0xff888888),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          border: Border.all(color: const Color(0xffdddddd)),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          qq ? (demo.userCard['个人状态'] ?? '记录生活中') : '＋ 状态',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xff666666),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const NativeSocialIcon(
                  'qr',
                  size: 18,
                  color: Color(0xff9aabb6),
                ),
                const SizedBox(width: 8),
                const NativeSocialIcon(
                  'right',
                  size: 16,
                  color: Color(0xffb2b2b2),
                ),
              ],
            ),
          ),
        ),
      ),
      const SizedBox(height: 8),
      if (qq)
        _group([
          _menu(
            '个人状态',
            'smile',
            () => widget.navigate('status'),
            note: demo.userCard['个人状态'] ?? '记录生活中',
            color: const Color(0xff68a394),
          ),
          _menu('我的空间', 'image', () => widget.navigate('moments')),
        ])
      else
        _group([
          _menu(
            '服务',
            'wallet',
            () => widget.navigate('services'),
            color: const Color(0xff07c160),
          ),
        ]),
      _group([
        _menu(
          '收藏',
          qq ? 'star' : 'box',
          () => widget.navigate('favorites'),
          color: const Color(0xfffa9d3b),
        ),
        _menu(
          qq ? '相册' : '朋友圈',
          'image',
          () => widget.navigate(qq ? 'albums' : 'moments'),
        ),
        if (!qq) _menu('卡包', 'wallet', () => widget.navigate('cards')),
        _menu(
          '表情',
          'smile',
          () => widget.go('/stickers'),
          color: const Color(0xfffa9d3b),
        ),
        if (qq) _menu('文件', 'folder', () => widget.navigate('files')),
      ]),
      _group([_menu('设置', 'settings', () => widget.navigate('settings'))]),
    ]);
  }

  Widget _calls() {
    final calls = _attachments({'call'});
    return _list([
      const SizedBox(height: 12),
      _group([
        _menu('语音通话', 'phone', _voiceCallPreview),
        const SocialExtraMenuRow(
          label: '视频通话',
          icon: 'video',
          note: '开发中',
          enabled: false,
          onTap: null,
        ),
      ]),
      if (calls.isNotEmpty) _note('最近通话'),
      for (final call in calls)
        Material(
          color: Colors.white,
          child: InkWell(
            onTap: () {
              final index = demo.conversations.indexOf(call.$1);
              if (index >= 0) demo.selectChat(index);
              _voiceCallPreview();
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              constraints: const BoxConstraints(minHeight: 70),
              child: Row(
                children: [
                  _avatar(call.$1.personaId ?? ''),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          call.$1.title,
                          style: const TextStyle(fontSize: 17),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          '${(call.$2['payload'] as Map)['video'] == true ? '视频' : '语音'}通话 · ${(call.$2['payload'] as Map)['duration']}秒',
                          style: const TextStyle(
                            fontSize: 14,
                            color: Color(0xffa1a1a1),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Column(
                    children: [
                      Text(
                        (call.$2['created'] as String)
                            .replaceAll('T', ' ')
                            .substring(0, 16),
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xffaaaaaa),
                        ),
                      ),
                      const SizedBox(height: 5),
                      const NativeSocialIcon(
                        'phone',
                        size: 18,
                        color: Color(0xff719fd0),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      if (calls.isEmpty) _note('暂无通话记录'),
    ]);
  }

  Future<void> _voiceCallPreview() => _showPage<void>('语音通话', (page) {
    final chat = demo.conversations.elementAtOrNull(demo.conversation);
    final role = _role(chat?.personaId ?? '');
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 50, 24, 24),
      children: [
        if (role != null) ...[
          Center(
            child: NativeSocialPortrait(
              mode: widget.mode,
              persona: role,
              size: 86,
              large: true,
              borderRadius: 12,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            role.name,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w500),
          ),
          _note('使用 Skivu 角色语音引擎'),
          SocialExtraButton(
            label: '开始语音通话',
            onTap: () {
              Navigator.pop(page);
              widget.go('/call');
            },
            color: _accent,
          ),
        ] else ...[
          _note('请先选择一个有效的角色独立对话。'),
          _menu('选择角色', 'user', () {
            Navigator.pop(page);
            widget.navigate('contacts');
          }),
        ],
      ],
    );
  });

  Widget _settings() {
    final qq = widget.mode == ChatUiMode.qq;
    return _list([
      _group([
        _menu(
          '社交与群聊',
          'settings',
          () => widget.go('/settings/social'),
          note: '自动动态、评论与群聊规则',
        ),
      ]),
      if (!qq) ...[
        _group([
          _menu(
            '账号与安全',
            null,
            () => _explain(
              '账号与安全',
              '微信号：${demo.userCard['社交账号'] ?? ''}\n本地演示资料，不连接微信账号。',
            ),
          ),
          _menu('青少年模式', null, () => _explain('青少年模式', '本地界面预览，未接入真实平台服务。')),
          _menu('关怀模式', null, () => _explain('关怀模式', '本地界面预览，未接入真实平台服务。')),
        ]),
        _group([
          _menu('新消息通知', null, _notificationPage),
          _menu('聊天', null, () => _chatSettings('聊天')),
          _menu('通用', null, () => _chatSettings('通用')),
        ]),
        _section('隐私'),
        _group([
          _menu(
            '朋友权限',
            null,
            () => _explain('可见范围', '当前内容只在此设备保存，不同步到真实社交平台。'),
          ),
          _menu(
            '个人信息与权限',
            null,
            () => _explain('个人信息与权限', '本机资料和动态仅保存在此设备。相册、相机等权限仅在使用对应系统入口时请求。'),
          ),
        ]),
        _group([
          _menu('帮助与反馈', null, () => _explain('帮助与反馈', '本地界面预览，未接入真实平台服务。')),
          _menu('关于微信', null, _about),
        ]),
      ] else ...[
        _group([
          _menu('个人资料', 'user', _editSocialProfile),
          _menu(
            '聊天外观',
            'sliders',
            () => widget.go('/settings/appearance'),
            note: '玻璃、胶囊与信息条',
          ),
          _menu(
            '字体与排版',
            'sliders',
            _fontPage,
            note: '${nativeSocialLocalOptions.fontSize} px',
          ),
        ]),
        _group([
          _switchRow(
            '新消息通知',
            nativeSocialLocalOptions.notifications,
            (v) => nativeSocialLocalOptions.setNotification(v),
          ),
          _switchRow(
            '免打扰模式',
            nativeSocialLocalOptions.quiet,
            (v) => nativeSocialLocalOptions.setQuiet(v),
          ),
          _menu(
            '隐私与可见范围',
            'user',
            () => _explain('可见范围', '当前内容仅保存在此设备，不同步到真实社交平台。'),
            note: '仅此预览',
          ),
          _menu('关于此界面', 'cloud', _about, note: 'Skivu 社交模式'),
        ]),
      ],
      _group([
        _menu('原版全部设置', 'settings', () => widget.go('/settings')),
        _menu('完整角色卡', 'user', _editBaseProfile),
        _menu('回到原版工作区', 'cloud', _classic),
      ]),
      _migrationStatus(),
    ]);
  }

  Future<void> _editBaseProfile() => editUserCard(context);
  Future<void> _editAvatar() => _showPage<void>(
    '更换头像',
    (page) => _list([
      _menu('从相册选择头像', 'image', () async {
        Navigator.pop(page);
        await _applyAvatar(false);
      }),
      if (demo.userAvatar != null)
        _menu('恢复默认头像', 'user', () async {
          Navigator.pop(page);
          await _applyAvatar(true);
        }),
    ]),
  );
  Future<void> _applyAvatar(bool reset) async {
    try {
      final bytes = reset ? null : await pickCharacterAvatar(user: true);
      if (!reset && bytes == null) return;
      demo.userAvatar = bytes;
      demo.changed();
      await demo.saveChats();
      _notice(demo.storageError ?? '头像已保存');
    } catch (_) {
      _notice('请选择3MB以内的图片，头像未更改。');
    }
  }

  Future<void> _editSocialProfile() => _showPage<void>(
    '编辑个人资料',
    (page) => SocialNativeProfileForm(
      mode: widget.mode,
      onDone: () => Navigator.pop(page),
      onAvatar: _editAvatar,
    ),
  );

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
        Container(
          color: Colors.white,
          padding: const EdgeInsets.all(17),
          child: Text(
            status,
            style: const TextStyle(fontSize: 13, height: 1.6),
          ),
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

  Widget _scan() => Padding(
    padding: const EdgeInsets.only(bottom: 52),
    child: ColoredBox(
      color: const Color(0xff242526),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(24, 54, 24, 35),
        children: [
          Center(
            child: Container(
              width: 210,
              height: 210,
              decoration: BoxDecoration(
                border: Border.all(color: const Color(0xff07c160), width: 2),
              ),
              child: const Center(
                child: NativeSocialIcon('qr', size: 65, color: Colors.white54),
              ),
            ),
          ),
          const SizedBox(height: 25),
          const Text(
            '识别 Skivu 角色码和虚拟钱包码',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              height: 1.7,
              color: Color(0xffdddddd),
            ),
          ),
          const SizedBox(height: 30),
          Center(
            child: SizedBox(
              width: widget.mode == ChatUiMode.qq ? double.infinity : 218,
              child: SocialExtraButton(
                label: _picking ? '识别中…' : '拍照或从相册选择二维码',
                color: _accent,
                onTap: _picking
                    ? null
                    : () => _showPage<void>(
                        '选择二维码图片',
                        (c) => _list([
                          _menu('拍照', 'camera', () {
                            Navigator.pop(c);
                            _scanPhoto(ImageSource.camera);
                          }),
                          _menu('从相册选择', 'image', () {
                            Navigator.pop(c);
                            _scanPhoto(ImageSource.gallery);
                          }),
                        ]),
                      ),
              ),
            ),
          ),
          const SizedBox(height: 24),
          GestureDetector(
            onTap: () async {
              final text = await _input('输入二维码内容', maxLength: 500);
              if (text != null && mounted) _openCode(text);
            },
            child: const Text(
              '输入二维码内容',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Color(0xffdddddd)),
            ),
          ),
        ],
      ),
    ),
  );

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

  Future<T?> _showPage<T>(
    String title,
    Widget Function(BuildContext) builder,
  ) => Navigator.of(context).push<T>(
    PageRouteBuilder<T>(
      transitionDuration: const Duration(milliseconds: 180),
      reverseTransitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (page, _, _) => Theme(
        data: Theme.of(context).copyWith(
          scaffoldBackgroundColor: const Color(0xffededed),
          inputDecorationTheme: InputDecorationTheme(
            filled: true,
            fillColor: Colors.white,
            contentPadding: const EdgeInsets.all(12),
            labelStyle: const TextStyle(fontSize: 12, color: Color(0xff637987)),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: const BorderSide(color: Color(0xffdce5eb)),
            ),
          ),
        ),
        child: Scaffold(
          resizeToAvoidBottomInset: true,
          body: SafeArea(
            child: Column(
              children: [
                Container(
                  height: 54,
                  color: widget.mode == ChatUiMode.qq
                      ? Colors.white
                      : const Color(0xffededed),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      _iconAction(
                        '返回',
                        'interaction-back',
                        () => Navigator.pop(page),
                      ),
                      Expanded(
                        child: Text(
                          title,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w500,
                            color: Color(0xff191919),
                          ),
                        ),
                      ),
                      const SizedBox(width: 40),
                    ],
                  ),
                ),
                Expanded(
                  child: DefaultTextStyle(
                    style: const TextStyle(
                      fontSize: 15,
                      color: Color(0xff191919),
                      fontFamily: 'SkiSans',
                    ),
                    child: builder(page),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      transitionsBuilder: (_, animation, _, child) => SlideTransition(
        position: Tween(begin: const Offset(1, 0), end: Offset.zero).animate(
          CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
        ),
        child: child,
      ),
    ),
  );
  Future<void> _explain(String title, String text, {Widget? illustration}) =>
      _showPage<void>(
        title,
        (_) => ListView(
          children: [if (illustration != null) illustration, _note(text)],
        ),
      );
  Future<String?> _input(String title, {required int maxLength}) async {
    final controller = TextEditingController();
    final result = await _showPage<String>(
      title,
      (page) => ListView(
        padding: const EdgeInsets.all(18),
        children: [
          TextField(
            controller: controller,
            autofocus: true,
            minLines: 2,
            maxLines: 5,
            maxLength: maxLength,
            decoration: InputDecoration(labelText: title),
          ),
          const SizedBox(height: 20),
          SocialExtraButton(
            label: '确定',
            onTap: () => Navigator.pop(page, controller.text),
            color: _accent,
          ),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    controller.dispose();
    return result;
  }

  Future<void> _restoreLocalPreferences() => nativeSocialLocalOptions.restore();
  Widget _switchRow(String title, bool value, ValueChanged<bool> update) =>
      SocialExtraMenuRow(
        label: title,
        onTap: () => update(!value),
        trailing: GestureDetector(
          onTap: () => update(!value),
          child: Semantics(
            label: title,
            toggled: value,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: 42,
              height: 24,
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                color: value
                    ? const Color(0xff07c160)
                    : const Color(0xffcbd5dc),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Align(
                alignment: value ? Alignment.centerRight : Alignment.centerLeft,
                child: Container(
                  width: 18,
                  height: 18,
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
  Future<void> _notificationPage() => _showPage<void>(
    '新消息通知',
    (_) => AnimatedBuilder(
      animation: nativeSocialLocalOptions,
      builder: (_, _) => _list([
        _switchRow(
          '接收新消息通知',
          nativeSocialLocalOptions.notifications,
          (v) => nativeSocialLocalOptions.setNotification(v),
        ),
        _note('本机界面预览开关，不申请系统通知权限。'),
      ]),
    ),
  );
  Future<void> _chatSettings(String title) => _showPage<void>(
    title,
    (page) => _list([
      _menu('字体大小', 'sliders', _fontPage),
      _menu('聊天背景与外观', 'image', () {
        Navigator.pop(page);
        widget.go('/settings/appearance');
      }),
    ]),
  );
  Future<void> _fontPage() => _showPage<void>(
    '消息字号',
    (page) => AnimatedBuilder(
      animation: nativeSocialLocalOptions,
      builder: (_, _) => _list([
        for (final size in [13, 14, 15, 16, 18])
          SocialExtraMenuRow(
            label: '$size px',
            note: nativeSocialLocalOptions.fontSize == size ? '当前字号' : null,
            onTap: () async {
              await nativeSocialLocalOptions.setFont(size);
              if (page.mounted) Navigator.pop(page);
            },
          ),
        _note('仅调整微信/QQ社交界面消息字号，不修改原版全局外观。'),
      ]),
    ),
  );
  Future<void> _about() => _explain(
    widget.mode == ChatUiMode.qq ? '关于此界面' : '关于微信',
    'Skivu 微信式 / QQ式本机社交界面。角色、聊天、动态和收藏与Skivu数据共用；未连接真实微信或QQ平台。',
  );
  Future<void> _classic() async {
    final saved = await uiPlugins.apply(ChatUiMode.classic);
    if (!saved) _notice(uiPlugins.error);
  }

  Widget _statusPage() => _list([
    for (final value in ['记录生活中', '忙里偷闲', '听歌中'])
      _menu(value, null, () async {
        demo.userCard = {...demo.userCard, '个人状态': value};
        demo.changed();
        await demo.saveChats();
        _notice(demo.storageError);
        if (mounted) widget.onBack();
      }, note: demo.userCard['个人状态'] == value ? '当前状态' : null),
  ]);
  Widget _miniapps() => _list([
    _section('最近使用'),
    _group([
      _menu(
        '天气小助手',
        'cloud',
        () => _explain(
          '天气小助手',
          '杭州\n24°\n晴转多云 · 适合散步\n界面示例天气，非实时数据。',
          illustration: Container(
            height: 120,
            color: const Color(0xffd4e8f1),
            child: const Center(
              child: NativeSocialIcon(
                'cloud',
                size: 50,
                color: Color(0xff7193a9),
              ),
            ),
          ),
        ),
        note: '今天也要有好心情',
      ),
      _menu(
        '随手记',
        'box',
        _notePage,
        note: '灵感不丢失',
        color: const Color(0xffc29b6b),
      ),
      _menu(
        '一起做计划',
        'check',
        () => _explain(
          '一起做计划',
          '周六 · 沿河散步　10:00\n周日 · 林间书店　14:00\n\n本机计划示例，未建立日历或联网预约。',
        ),
        note: '给生活留一点余地',
        color: const Color(0xff79a894),
      ),
    ]),
    _featureNote('这些是本地界面示例'),
  ]);
  Future<void> _notePage() async {
    final controller = TextEditingController(
      text: nativeSocialLocalOptions.note,
    );
    await _showPage<void>(
      '随手记',
      (page) => ListView(
        padding: const EdgeInsets.all(18),
        children: [
          TextField(
            controller: controller,
            minLines: 8,
            maxLines: 15,
            maxLength: 4000,
            decoration: const InputDecoration(
              labelText: '今天的灵感',
              hintText: '记下来吧…',
            ),
          ),
          SocialExtraButton(
            label: '保存笔记',
            onTap: () async {
              await nativeSocialLocalOptions.setNote(controller.text);
              if (page.mounted) Navigator.pop(page);
            },
            color: _accent,
          ),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    controller.dispose();
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
  const NativeSocialQr({super.key, required this.data, this.size = 220});
  final String data;
  final double size;
  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Skivu二维码',
    image: true,
    child: SizedBox.square(
      dimension: size,
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
    final step = size.shortestSide / (count + 8);
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

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'cloud_wallpapers.dart';
import 'wallpaper.dart';
import 'appearance.dart';
import 'skymoni_palette.dart';
import 'cloud_wallpaper_application.dart';

class CloudWallpaperGallery extends StatefulWidget {
  const CloudWallpaperGallery({
    super.key,
    required this.controller,
    this.service,
    this.preferences,
  });
  final WallpaperController controller;
  final CloudWallpaperService? service;
  final AppearancePreferences? preferences;
  @override
  State<CloudWallpaperGallery> createState() => _CloudWallpaperGalleryState();
}

class _CloudWallpaperGalleryState extends State<CloudWallpaperGallery> {
  static const _cacheKey = 'skivu.cloud-wallpapers.catalog.v1';
  static const _selectionKey = 'skivu.cloud-wallpapers.selection.v1';
  late final CloudWallpaperService _service;
  late final bool _ownsService;
  CloudWallpaperCatalog? _catalog;
  String? _error, _selectedCloud, _selectedLocal;
  bool _loading = false, _opened = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _ownsService = widget.service == null;
    _service = widget.service ?? CloudWallpaperService();
  }

  @override
  void dispose() {
    _generation++;
    if (_ownsService) _service.close();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
      final selection = prefs.getString(_selectionKey);
      if (selection != null) {
        try {
          final data = jsonDecode(selection) as Map<String, dynamic>;
          _selectedCloud = data['cloud'] as String?;
          _selectedLocal = data['local'] as String?;
        } catch (_) {
          /* Ignore damaged optional selection metadata. */
        }
      }
      final cached = prefs.getString(_cacheKey);
      if (_catalog == null && cached != null) {
        try {
          final catalog = CloudWallpaperCatalog.parse(jsonDecode(cached));
          if (mounted) setState(() => _catalog = catalog);
        } catch (_) {
          /* Invalid cached public data never replaces the wallpaper. */
        }
      }
    } catch (_) {
      // A damaged optional cache must not prevent a fresh public request.
    }
    try {
      final catalog = await _service.fetchCatalog();
      if (!mounted) return;
      setState(() => _catalog = catalog);
      try {
        await prefs?.setString(_cacheKey, jsonEncode(catalog.toJson()));
      } catch (_) {
        // Fresh data remains usable even if the optional cache cannot save.
      }
    } catch (_) {
      if (mounted) setState(() => _error = '暂时无法刷新，已保留本机背景和缓存列表。');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _preview(CloudWallpaper item) async {
    final generation = ++_generation;
    var pending = false;
    String? error;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(item.name),
          content: SizedBox(
            width: 300,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: SizedBox(
                      height: 290,
                      width: double.infinity,
                      child: Image.network(
                        item.thumbnail.toString(),
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => const Center(
                          child: Icon(Icons.broken_image_outlined),
                        ),
                      ),
                    ),
                  ),
                  if (item.description.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(item.description),
                    ),
                  Padding(
                    padding: EdgeInsets.only(top: 10),
                    child: Text(
                      '${skymoniThemeNames[item.colorTheme]} · ${item.mode == 'dark'
                          ? '深色'
                          : item.mode == 'light'
                          ? '浅色'
                          : '跟随外观'}\n同时应用壁纸附带的主题配色与明暗效果。',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(
                        error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: pending || widget.controller.busy
                  ? null
                  : () async {
                      update(() {
                        pending = true;
                        error = null;
                      });
                      try {
                        final downloaded = await _service.download(item);
                        if (!mounted ||
                            !dialogContext.mounted ||
                            generation != _generation)
                          return;
                        final bytes = await compute(prepareCloudWallpaper, (
                          downloaded,
                          item.width,
                          item.height,
                        ));
                        if (!mounted ||
                            !dialogContext.mounted ||
                            generation != _generation)
                          return;
                        final applied = await applyCloudWallpaper(
                          item: item,
                          bytes: bytes,
                          background: widget.controller,
                          preferences: widget.preferences ?? appearance,
                          isCurrent: () =>
                              mounted &&
                              dialogContext.mounted &&
                              generation == _generation,
                        );
                        if (!applied) return;
                        _selectedCloud = item.id;
                        _selectedLocal = widget.controller.data?.id;
                        try {
                          final prefs = await SharedPreferences.getInstance();
                          await prefs.setString(
                            _selectionKey,
                            jsonEncode({
                              'cloud': _selectedCloud,
                              'local': _selectedLocal,
                            }),
                          );
                        } catch (_) {
                          /* Image persistence already completed successfully. */
                        }
                        if (mounted) setState(() {});
                        if (dialogContext.mounted)
                          Navigator.of(dialogContext).pop();
                      } catch (_) {
                        if (dialogContext.mounted)
                          update(() => error = '壁纸或主题未能保存，请重试。');
                      } finally {
                        if (dialogContext.mounted)
                          update(() => pending = false);
                      }
                    },
              child: Text(pending ? '正在下载并保存…' : '使用这张壁纸'),
            ),
          ],
        ),
      ),
    );
    if (generation == _generation) _generation++;
  }

  @override
  Widget build(BuildContext context) => ExpansionTile(
    key: const ValueKey('cloud-wallpaper-gallery'),
    tilePadding: EdgeInsets.zero,
    title: const Text('云端壁纸'),
    subtitle: const Text('与 Skymoni 同步壁纸及主题配色', style: TextStyle(fontSize: 12)),
    onExpansionChanged: (expanded) {
      if (expanded && !_opened) {
        _opened = true;
        _refresh();
      }
    },
    children: [
      Row(
        children: [
          Expanded(
            child: Text(
              _loading ? '正在刷新…' : '下载后离线也能使用',
              style: const TextStyle(fontSize: 12),
            ),
          ),
          IconButton(
            tooltip: '刷新云端壁纸',
            onPressed: _loading ? null : _refresh,
            icon: _loading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
          ),
        ],
      ),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(_error!),
        ),
      if (_catalog != null && _catalog!.items.isEmpty)
        const Padding(padding: EdgeInsets.all(12), child: Text('云端壁纸正在准备中。')),
      LayoutBuilder(
        builder: (context, box) => Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final item in _catalog?.items ?? <CloudWallpaper>[])
              SizedBox(
                width: (box.maxWidth - 12) / 2,
                child: Card(
                  clipBehavior: Clip.antiAlias,
                  margin: EdgeInsets.zero,
                  child: InkWell(
                    onTap: () => _preview(item),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        AspectRatio(
                          aspectRatio: 3 / 4,
                          child: Image.network(
                            item.thumbnail.toString(),
                            fit: BoxFit.cover,
                            cacheWidth: 400,
                            errorBuilder: (_, __, ___) => const Center(
                              child: Icon(Icons.landscape_outlined),
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                item.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                _selectedCloud == item.id &&
                                        _selectedLocal ==
                                            widget.controller.data?.id
                                    ? '当前使用'
                                    : item.mode == 'dark'
                                    ? '深色背景'
                                    : item.mode == 'light'
                                    ? '浅色背景'
                                    : '背景图片',
                                style: const TextStyle(fontSize: 11),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
      const SizedBox(height: 16),
    ],
  );
}

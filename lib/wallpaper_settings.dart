import 'package:flutter/material.dart';
import 'wallpaper.dart';
import 'widgets.dart';
import 'state.dart';

class WallpaperSettings extends StatelessWidget {
  const WallpaperSettings({super.key, this.controller, this.onChosen});
  final WallpaperController? controller;
  final VoidCallback? onChosen;

  @override
  Widget build(BuildContext context) {
    final model = controller ?? wallpaper;
    return AnimatedBuilder(
      animation: model,
      builder: (context, _) {
        final data = model.data;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            label('自定义壁纸', size: 16, weight: FontWeight.w500),
            const SizedBox(height: 8),
            label('铺满整个界面，让玻璃透出你的风景。', size: 12, color: muted),
            if (data != null) ...[
              const SizedBox(height: 16),
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Image.memory(
                    data.bytes,
                    fit: BoxFit.cover,
                    excludeFromSemantics: true,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 14),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                FilledButton.icon(
                  onPressed: model.busy
                      ? null
                      : () async {
                          if (await model.choose()) onChosen?.call();
                        },
                  icon: model.busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(
                          Icons.add_photo_alternate_outlined,
                          size: 18,
                        ),
                  label: Text(
                    model.busy
                        ? '正在处理…'
                        : data == null
                        ? '选择图片'
                        : '更换图片',
                  ),
                ),
                if (data != null)
                  TextButton(
                    onPressed: model.busy ? null : model.reset,
                    child: const Text('恢复默认'),
                  ),
              ],
            ),
            if (data != null) ...[
              const SizedBox(height: 18),
              label('背景模糊 · ${data.blur.round()}', size: 12),
              Slider(
                key: const ValueKey('wallpaper-blur'),
                value: data.blur,
                max: 18,
                divisions: 18,
                semanticFormatterCallback: (v) => '模糊 ${v.round()}',
                onChanged: model.busy ? null : (v) => model.style(blur: v),
                onChangeEnd: (_) => model.saveStyle(),
              ),
              label('背景压暗 · ${(data.dim * 100).round()}%', size: 12),
              Slider(
                key: const ValueKey('wallpaper-dim'),
                value: data.dim,
                max: .65,
                divisions: 65,
                semanticFormatterCallback: (v) => '压暗 ${(v * 100).round()}%',
                onChanged: model.busy ? null : (v) => model.style(dim: v),
                onChangeEnd: (_) => model.saveStyle(),
              ),
            ],
            if (model.error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  model.error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const SizedBox(height: 8),
            label('仅保存在本机 · 自动保存 · 居中铺满', size: 11, color: muted),
          ],
        );
      },
    );
  }
}

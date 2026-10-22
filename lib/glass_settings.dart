import 'package:flutter/material.dart';
import 'drawer_motion.dart';
import 'glass_preferences.dart';
import 'state.dart';
import 'widgets.dart';
import 'chat_bubble_surface.dart';

class GlassSettings extends StatelessWidget {
  const GlassSettings({super.key, this.preferences});
  final GlassPreferences? preferences;

  @override
  Widget build(BuildContext context) {
    final model = preferences ?? glassPreferences;
    final deck = context.findAncestorWidgetOfExactType<SlideDeck>();
    return AnimatedBuilder(
      animation: model,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              label('侧栏玻璃', size: 16, weight: FontWeight.w500),
              TextButton(onPressed: model.reset, child: const Text('恢复默认模糊')),
            ],
          ),
          label('左右独立调节，数值越大越朦胧。', size: 12, color: muted),
          const SizedBox(height: 12),
          for (final left in [true, false]) ...[
            Row(
              children: [
                Expanded(child: label(left ? '左侧导航' : '右侧工作区', size: 13)),
                TextButton(
                  onPressed: deck == null
                      ? null
                      : () => deck.motion.toggle(left ? 1 : -1),
                  child: Text(left ? '预览左侧' : '预览右侧'),
                ),
                TinyTag('${(left ? model.leftBlur : model.rightBlur).round()}'),
              ],
            ),
            Slider(
              key: ValueKey(left ? 'left-glass-blur' : 'right-glass-blur'),
              value: left ? model.leftBlur : model.rightBlur,
              max: 30,
              divisions: 30,
              label: '${(left ? model.leftBlur : model.rightBlur).round()}',
              semanticFormatterCallback: (v) =>
                  '${left ? '左侧导航' : '右侧工作区'}模糊 ${v.round()}',
              onChanged: (v) => model.setBlur(leftSide: left, value: v),
              onChangeEnd: (_) => model.save(),
            ),
          ],
          label('0 清晰 · 30 朦胧 · 松手自动保存', size: 11, color: muted),
          if (model.error != null)
            Text(
              model.error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    );
  }
}

class BubbleGlassSettings extends StatelessWidget {
  const BubbleGlassSettings({super.key, this.preferences});
  final GlassPreferences? preferences;

  @override
  Widget build(BuildContext context) {
    final model = preferences ?? glassPreferences;
    return AnimatedBuilder(
      animation: Listenable.merge([model, demo]),
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              label('对话气泡', size: 16, weight: FontWeight.w500),
              TextButton(
                onPressed: model.resetBubbles,
                child: const Text('恢复默认气泡'),
              ),
            ],
          ),
          label('调整气泡背后的模糊，消息文字保持清晰。', size: 12, color: muted),
          const SizedBox(height: 16),
          for (final user in [true, false]) ...[
            Row(
              children: [
                Expanded(child: label(user ? '我的消息' : '对方回复', size: 13)),
                TinyTag(
                  '${(user ? model.userBlur : model.assistantBlur).round()}',
                ),
              ],
            ),
            const SizedBox(height: 10),
            Align(
              alignment: user ? Alignment.centerRight : Alignment.centerLeft,
              child: ChatBubbleSurface(
                user: user,
                preferences: model,
                child: Text(
                  user ? '今天想和你聊一会儿。' : '我在，慢慢说就好。',
                  style: chatMessageStyle(context, user, size: 13),
                ),
              ),
            ),
            Slider(
              key: ValueKey(
                user ? 'user-bubble-blur' : 'assistant-bubble-blur',
              ),
              value: user ? model.userBlur : model.assistantBlur,
              max: 30,
              divisions: 30,
              label: '${(user ? model.userBlur : model.assistantBlur).round()}',
              semanticFormatterCallback: (v) =>
                  '${user ? '我的消息' : '对方回复'}模糊 ${v.round()}',
              onChanged: (v) => model.setBubbleBlur(user: user, value: v),
              onChangeEnd: (_) => model.save(),
            ),
          ],
          label('0 清晰 · 30 朦胧 · 松手自动保存', size: 11, color: muted),
          if (model.error != null)
            Text(
              model.error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'ui_plugins.dart';
import 'plugin_market.dart';
import 'plugin_market_widgets.dart';

Future<void> _removePlugin(
  BuildContext context,
  ChatUiMode mode,
  PluginMarket market,
  UiPluginSettings settings,
) async {
  final yes = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('卸载${mode.title}？'),
      content: const Text('卸载后保留角色、聊天记录和外观设置，可随时重新安装。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('卸载'),
        ),
      ],
    ),
  );
  if (yes != true || !context.mounted) return;
  final removed = await market.uninstall(mode, settings);
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(removed ? '插件已卸载' : market.error ?? '卸载未完成，请重试。')),
    );
  }
}

/// The two audited presenters use the same persisted mode in the sidebar and
/// plugin page. Turning the selected presenter off restores the classic UI.
class UiPluginOptions extends StatelessWidget {
  const UiPluginOptions({
    super.key,
    required this.go,
    this.compact = false,
    this.preferences,
    this.market,
  });
  final ValueChanged<String> go;
  final bool compact;
  final UiPluginSettings? preferences;
  final PluginMarket? market;

  @override
  Widget build(BuildContext context) {
    final model = preferences ?? uiPlugins;
    final library = market ?? pluginMarket;
    Future<void> toggle(ChatUiMode mode, bool enabled) async {
      if (enabled && library.installedFor(mode) == null) {
        go('/market');
        return;
      }
      if (await model.setEnabled(mode, enabled)) {
        if (context.mounted) go('/chat');
      }
    }

    return AnimatedBuilder(
      animation: Listenable.merge([model, library]),
      builder: (context, _) {
        final options = [
          for (final mode in [ChatUiMode.qq, ChatUiMode.wechat])
            if (compact) ...[
              if (library.installedFor(mode) != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Material(
                    color: Colors.white.withValues(
                      alpha: model.mode == mode ? .36 : .12,
                    ),
                    borderRadius: BorderRadius.circular(16),
                    child: InkWell(
                      key: ValueKey('sidebar-plugin-${mode.name}'),
                      borderRadius: BorderRadius.circular(16),
                      onTap: model.busy || library.workingId != null
                          ? null
                          : () => toggle(mode, model.mode != mode),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(8, 8, 2, 8),
                        child: Row(
                          children: [
                            Container(
                              width: 42,
                              height: 42,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.white.withValues(alpha: .28),
                              ),
                              child: const Icon(
                                Icons.extension_outlined,
                                size: 23,
                                color: Color(0xff38434b),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                library.installedFor(mode)!.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 16,
                                  color: Color(0xff17212b),
                                ),
                              ),
                            ),
                            Semantics(
                              label: '启用${mode.title}',
                              child: Switch.adaptive(
                                key: ValueKey(
                                  'sidebar-plugin-toggle-${mode.name}',
                                ),
                                value: model.mode == mode,
                                activeTrackColor: const Color(0xff76a9bd),
                                activeThumbColor: const Color(0xfff8fcff),
                                inactiveThumbColor: const Color(0xff81959e),
                                inactiveTrackColor: Colors.white.withValues(
                                  alpha: .28,
                                ),
                                trackOutlineColor: const WidgetStatePropertyAll(
                                  Color(0x3351646e),
                                ),
                                materialTapTargetSize:
                                    MaterialTapTargetSize.padded,
                                onChanged:
                                    model.busy || library.workingId != null
                                    ? null
                                    : (enabled) => toggle(mode, enabled),
                              ),
                            ),
                            PopupMenuButton<String>(
                              key: ValueKey('sidebar-plugin-menu-${mode.name}'),
                              tooltip: '${mode.title}管理',
                              enabled: !model.busy && library.workingId == null,
                              icon: const Icon(Icons.more_horiz, size: 21),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(minWidth: 140),
                              onSelected: (value) {
                                if (value == 'remove') {
                                  _removePlugin(context, mode, library, model);
                                }
                              },
                              itemBuilder: (_) => [
                                const PopupMenuItem(
                                  value: 'remove',
                                  child: Text('卸载插件'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ] else
              Card(
                elevation: 0,
                margin: const EdgeInsets.only(bottom: 12),
                color: Colors.white.withValues(alpha: .65),
                child: SwitchListTile.adaptive(
                  key: ValueKey('plugin-toggle-${mode.name}'),
                  activeTrackColor: const Color(0xff76a9bd),
                  activeThumbColor: const Color(0xfff8fcff),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 12,
                  ),
                  secondary: Icon(
                    Icons.chat_bubble_outline,
                    color: mode == ChatUiMode.qq
                        ? const Color(0xff0099ff)
                        : const Color(0xff07c160),
                  ),
                  title: Text(
                    mode == ChatUiMode.qq ? 'QQ' : '微信',
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: Text(
                    '${library.installedFor(mode) == null
                        ? '未安装，前往市场安装'
                        : model.mode == mode
                        ? '已启用'
                        : '未启用'} · ${mode == ChatUiMode.qq ? '消息、联系人、动态' : '消息、通讯录、发现、我'}',
                    style: const TextStyle(fontSize: 12, height: 1.7),
                  ),
                  value: model.mode == mode,
                  onChanged: model.busy ? null : (v) => toggle(mode, v),
                ),
              ),
        ];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ...options,
            if (model.error != null)
              Text(
                model.error!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 12,
                ),
              ),
          ],
        );
      },
    );
  }
}

class UiPluginsPage extends StatefulWidget {
  const UiPluginsPage({
    super.key,
    required this.go,
    this.preferences,
    this.market,
    this.autoRefresh = true,
  });
  final ValueChanged<String> go;
  final UiPluginSettings? preferences;
  final PluginMarket? market;
  final bool autoRefresh;
  @override
  State<UiPluginsPage> createState() => _UiPluginsPageState();
}

class _UiPluginsPageState extends State<UiPluginsPage> {
  PluginMarket get market => widget.market ?? pluginMarket;
  UiPluginSettings get settings => widget.preferences ?? uiPlugins;

  @override
  void initState() {
    super.initState();
    if (widget.autoRefresh) Future.microtask(market.refresh);
  }

  Future<void> remove(ChatUiMode mode) =>
      _removePlugin(context, mode, market, settings);

  Color accent(ChatUiMode mode) =>
      mode == ChatUiMode.qq ? const Color(0xff2589d8) : const Color(0xff22a879);

  Widget glyph(ChatUiMode mode) => MarketGlyph(
    icon: mode == ChatUiMode.qq
        ? Icons.forum_rounded
        : Icons.chat_bubble_rounded,
    color: accent(mode),
  );

  void details(ChatUiMode mode, MarketPlugin? item) {
    if (item == null) return;
    showMarketDetails(
      context,
      name: item.name,
      description: item.description,
      icon: glyph(mode),
      guidance:
          '共用现有角色与聊天记录，无需额外设备权限。一次使用一种聊天界面，卸载后仍保留聊天记录。左右滑动可切换插件页面，从右侧中部向内拉出控制栏可返回原版。',
      details: [
        ('版本', item.version),
        ('开发者', '${item.metadata['author']}'),
        ('开源许可', '${item.metadata['license']}'),
        ('项目来源', '${item.metadata['repository']}'),
        ('适用版本', 'Skivu ${item.minHostVersion} 及以上'),
      ],
    );
  }

  Future<void> install(MarketPlugin available) async {
    final ok = await market.install(available);
    if (ok && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('插件已安装，可开启使用。')));
    }
  }

  Widget category({
    required String title,
    required String subtitle,
    required IconData icon,
    required Color color,
    required String route,
  }) => MarketPanel(
    padding: const EdgeInsets.all(16),
    onTap: () => widget.go(route),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MarketGlyph(icon: icon, color: color, size: 38),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const Icon(Icons.arrow_forward_rounded, size: 17),
          ],
        ),
        const SizedBox(height: 5),
        Text(
          subtitle,
          style: TextStyle(
            fontSize: 12,
            height: 1.5,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    ),
  );

  Widget pluginCard(ChatUiMode mode) {
    final installed = market.installedFor(mode);
    final available = market.catalog.where((p) => p.mode == mode).firstOrNull;
    final item = available ?? installed;
    final active = settings.mode == mode;
    final busy = market.workingId != null || market.loading || settings.busy;
    final upgrade =
        available != null &&
        installed != null &&
        comparePluginVersions(available.version, installed.version) > 0;
    final description = mode == ChatUiMode.qq
        ? '消息、联系人与动态空间，找回熟悉的聊天节奏。'
        : '聊天、朋友圈与个人主页，让角色融入日常。';
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: MarketPanel(
        onTap: item == null ? null : () => details(mode, item),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                glyph(mode),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        mode == ChatUiMode.qq ? 'QQ' : '微信',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        active
                            ? '正在使用'
                            : installed != null
                            ? '已安装'
                            : '聊天界面',
                        style: TextStyle(
                          fontSize: 12,
                          color: active
                              ? accent(mode)
                              : Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (installed == null || upgrade)
                  MarketAction(
                    key: ValueKey('plugin-install-${mode.name}'),
                    label: available != null && !available.compatible
                        ? '需更新'
                        : upgrade
                        ? '更新'
                        : '安装',
                    busy:
                        market.workingId == item?.id &&
                        market.workingId != null,
                    onPressed:
                        busy || available == null || !available.compatible
                        ? null
                        : () => install(available),
                  )
                else
                  PopupMenuButton<String>(
                    key: ValueKey('plugin-menu-${mode.name}'),
                    tooltip: '${mode.title}管理',
                    icon: const Icon(Icons.more_horiz_rounded),
                    onSelected: (value) {
                      if (value == 'details') details(mode, item);
                      if (value == 'remove') remove(mode);
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                        value: 'details',
                        child: Text('插件详情'),
                      ),
                      PopupMenuItem(
                        value: 'remove',
                        enabled: !busy,
                        child: const Text('卸载插件'),
                      ),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              description,
              style: TextStyle(
                fontSize: 13,
                height: 1.65,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            if (installed != null) ...[
              const SizedBox(height: 12),
              const Divider(height: 1),
              SwitchListTile.adaptive(
                key: ValueKey('plugin-toggle-${mode.name}'),
                activeTrackColor: accent(mode),
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('使用此界面', style: TextStyle(fontSize: 13)),
                value: active,
                onChanged: busy
                    ? null
                    : (v) async {
                        if (await settings.setEnabled(mode, v) && mounted)
                          widget.go('/chat');
                      },
              ),
            ],
            if (available != null && !available.compatible) ...[
              const SizedBox(height: 8),
              Text(
                '需要 Skivu ${available.minHostVersion} 及以上',
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([market, settings]),
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MarketHeader(
          title: '插件市场',
          subtitle: '发现新的聊天方式和实用工具。',
          actions: [
            IconButton(
              tooltip: '刷新插件市场',
              onPressed: market.loading || market.workingId != null
                  ? null
                  : market.refresh,
              icon: const Icon(Icons.refresh_rounded, size: 22),
            ),
          ],
        ),
        const SizedBox(height: 24),
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: category(
                  title: '工具箱',
                  subtitle: '提示词与更多玩法',
                  icon: Icons.widgets_rounded,
                  color: const Color(0xff8670c7),
                  route: '/open-plugins',
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: category(
                  title: '技能与工具',
                  subtitle: '让任务更得心应手',
                  icon: Icons.auto_awesome_rounded,
                  color: const Color(0xffbb8551),
                  route: '/extensions',
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 28),
        const Text(
          '聊天外观',
          style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 5),
        Text(
          '熟悉的界面，同样的陪伴。',
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 16),
        if (market.loading)
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: LinearProgressIndicator(minHeight: 2),
          ),
        if (market.error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: MarketPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    market.error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                      height: 1.6,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: market.loading || market.workingId != null
                        ? null
                        : market.refresh,
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: const Text('重试'),
                  ),
                ],
              ),
            ),
          ),
        for (final mode in [ChatUiMode.qq, ChatUiMode.wechat]) pluginCard(mode),
      ],
    ),
  );
}

import 'package:flutter/material.dart';
import 'ui_plugins.dart';
import 'plugin_market.dart';

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

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([market, settings]),
    builder: (context, _) {
      final modes = [ChatUiMode.qq, ChatUiMode.wechat];
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  '插件市场',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
                ),
              ),
              IconButton(
                tooltip: '刷新插件市场',
                onPressed: market.loading || market.workingId != null
                    ? null
                    : market.refresh,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            '从社区目录安装，选择你喜欢的聊天方式。',
            style: TextStyle(fontSize: 13, height: 1.7),
          ),
          const SizedBox(height: 18),
          Card(
            child: ListTile(
              leading: const Icon(Icons.hub_outlined),
              title: const Text('技能与 MCP 工具'),
              subtitle: const Text('安装任务技能，或连接自己的 MCP 服务'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => widget.go('/extensions'),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              leading: const Icon(Icons.extension_outlined),
              title: const Text('开放插件与开发者'),
              subtitle: const Text('独立应用、聊天动作、本地导入与第三方目录'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => widget.go('/open-plugins'),
            ),
          ),
          if (market.loading) const LinearProgressIndicator(),
          if (market.error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                market.error!,
                style: const TextStyle(color: Color(0xffa62f28), height: 1.6),
              ),
            ),
          for (final mode in modes)
            Builder(
              builder: (context) {
                final installed = market.installedFor(mode),
                    available = market.catalog
                        .where((p) => p.mode == mode)
                        .firstOrNull;
                final item = available ?? installed,
                    active = settings.mode == mode,
                    busy =
                        market.workingId != null ||
                        market.loading ||
                        settings.busy;
                final upgrade =
                    available != null &&
                    installed != null &&
                    comparePluginVersions(
                          available.version,
                          installed.version,
                        ) >
                        0;
                return Card(
                  elevation: 0,
                  color: Colors.white.withValues(alpha: .70),
                  margin: const EdgeInsets.only(bottom: 14),
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                color: mode == ChatUiMode.qq
                                    ? const Color(0xffe5f4ff)
                                    : const Color(0xffe7f8ed),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Icon(
                                Icons.chat_bubble_outline,
                                color: mode == ChatUiMode.qq
                                    ? const Color(0xff0099ff)
                                    : const Color(0xff07c160),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    mode == ChatUiMode.qq ? 'QQ' : '微信',
                                    style: const TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  Text(
                                    installed != null
                                        ? '已安装 ${installed.version}'
                                        : available != null
                                        ? '版本 ${available.version}'
                                        : '等待获取目录',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Color(0xff64717b),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        Text(
                          item?.description ?? '正在获取社区插件信息，连接后可安装。',
                          style: const TextStyle(fontSize: 13, height: 1.7),
                        ),
                        if (item != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              '${item.metadata['author']} · ${item.metadata['license']}\n共用本机角色与对话 · 无额外设备权限',
                              style: const TextStyle(
                                fontSize: 11,
                                height: 1.8,
                                color: Color(0xff64717b),
                              ),
                            ),
                          ),
                        const SizedBox(height: 12),
                        if (installed != null)
                          SwitchListTile.adaptive(
                            key: ValueKey('plugin-toggle-${mode.name}'),
                            activeTrackColor: const Color(0xff76a9bd),
                            activeThumbColor: const Color(0xfff8fcff),
                            contentPadding: EdgeInsets.zero,
                            title: const Text(
                              '启用',
                              style: TextStyle(fontSize: 15),
                            ),
                            value: active,
                            onChanged: busy
                                ? null
                                : (v) async {
                                    if (await settings.setEnabled(mode, v) &&
                                        mounted)
                                      widget.go('/chat');
                                  },
                          ),
                        if (installed == null || upgrade)
                          FilledButton.icon(
                            key: ValueKey('plugin-install-${mode.name}'),
                            onPressed:
                                busy ||
                                    available == null ||
                                    !available.compatible
                                ? null
                                : () async {
                                    final ok = await market.install(available);
                                    if (ok && context.mounted)
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        const SnackBar(
                                          content: Text('插件已安装，可开启使用。'),
                                        ),
                                      );
                                  },
                            icon: market.workingId == item?.id
                                ? const SizedBox(
                                    width: 17,
                                    height: 17,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.download_outlined, size: 19),
                            label: Text(
                              available != null && !available.compatible
                                  ? '需更新 App 至 ${available.minHostVersion}'
                                  : upgrade
                                  ? '更新插件'
                                  : '安装',
                            ),
                          ),
                        if (installed != null)
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton(
                              onPressed: busy ? null : () => remove(mode),
                              child: const Text('卸载'),
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          const Text(
            '同时启用一种界面。左右滑动切换插件页面；从右侧中部向内拉出控制栏可返回原版。卸载不删除聊天记录。',
            style: TextStyle(
              fontSize: 12,
              height: 1.7,
              color: Color(0xff64717b),
            ),
          ),
          const SizedBox(height: 18),
          const Text(
            'Skivu 社区 · github.com/skyjjgw/skivu-plugins',
            style: TextStyle(fontSize: 11, color: Color(0xff64717b)),
          ),
        ],
      );
    },
  );
}

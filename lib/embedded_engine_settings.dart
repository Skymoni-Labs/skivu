import 'package:flutter/material.dart';
import 'product_ui.dart';
import 'package:flutter/services.dart';
import 'device_engine.dart';
import 'cloud_coding_page.dart';
import 'engine_app_selection_page.dart';

/// Authorization belongs to the host. Models/plugins never operate this form.
class EmbeddedEngineSettings extends StatefulWidget {
  const EmbeddedEngineSettings({super.key});
  @override
  State<EmbeddedEngineSettings> createState() => _EmbeddedEngineSettingsState();
}

class _EmbeddedEngineSettingsState extends State<EmbeddedEngineSettings>
    with WidgetsBindingObserver {
  Map<String, dynamic> state = {};
  List<Map<String, dynamic>> apps = [];
  final pairPort = TextEditingController();
  final pairCode = TextEditingController();
  final connectPort = TextEditingController();
  bool busy = false;
  bool trustPeer = false;
  String? message;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    pairPort.dispose();
    pairCode.dispose();
    connectPort.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState value) {
    if (value == AppLifecycleState.resumed && !busy) refresh();
  }

  Future<void> run(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      message = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted)
        setState(
          () =>
              message = e is PlatformException ? e.message ?? '设备连接未完成。' : '$e',
        );
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> refresh() => run(() async {
    final value = await deviceEngine.status();
    final installed = await deviceEngine.installedApps();
    if (mounted)
      setState(() {
        state = value;
        apps = installed;
      });
  });
  Future<bool> update(String field, dynamic value) async {
    var saved = false;
    await run(() async {
      final next = {...state, field: value};
      final result = await deviceEngine.configure(
        enabled: next['enabled'] == true,
        system: next['system'] == true,
        control: next['control'] == true,
        shell: next['shell'] == true,
        packages: List<String>.from(next['packages'] as List? ?? []),
        allApplications: next['allApplications'] == true,
        recognitionMode: next['recognitionMode'] as String? ?? 'auto',
      );
      if (mounted) setState(() => state = result);
      saved = true;
    });
    return saved;
  }

  Future<void> chooseApps({bool selectedOnly = false}) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => EngineAppSelectionPage(
          apps: apps,
          selected: Set<String>.from(state['packages'] as List? ?? []),
          selectedOnly: selectedOnly,
          save: (selected) async {
            final saved = await update('packages', selected.toList());
            if (!saved) {
              throw PlatformException(
                code: 'APP_SCOPE_SAVE',
                message: message ?? '保存未完成，请重试。',
              );
            }
            return Set<String>.from(state['packages'] as List? ?? []);
          },
        ),
      ),
    );
  }

  Widget toggle(String field, String title, String description) =>
      SwitchListTile(
        title: Text(title),
        subtitle: Text(description),
        value: state[field] == true,
        onChanged: busy ? null : (v) => update(field, v),
      );
  Widget authorization(String name, String page, bool granted) => ListTile(
    title: Text(name),
    subtitle: Text(granted ? '已核对系统授权' : '尚未授权'),
    trailing: const Icon(Icons.open_in_new),
    onTap: busy
        ? null
        : () => run(() async {
            await deviceEngine.openAuthorization(page);
          }),
  );
  Widget portField(
    TextEditingController controller,
    String label, {
    bool secret = false,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: TextField(
      controller: controller,
      obscureText: secret,
      keyboardType: TextInputType.number,
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(secret ? 6 : 5),
      ],
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
    ),
  );
  int port(TextEditingController controller) {
    final value = int.tryParse(controller.text) ?? 0;
    if (value < 1024 || value > 65535)
      throw const FormatException('请输入系统显示的端口（1024–65535）。');
    return value;
  }

  @override
  Widget build(BuildContext context) => ProductScaffold(
    title: '手机操控',
    actions: [
      IconButton(
        onPressed: busy ? null : refresh,
        tooltip: '刷新设备状态',
        icon: const Icon(Icons.refresh_rounded),
      ),
    ],
    body: ListView(
      padding: const EdgeInsets.all(18),
      children: [
        if (busy) const LinearProgressIndicator(minHeight: 2),
        ProductSection(
          title: state['enabled'] == true ? '手机操控已开启' : '开启手机操控',
          subtitle: '选择需要的能力，并由你决定允许操作哪些应用。',
          icon: Icons.phonelink_setup_rounded,
          children: [toggle('enabled', '允许手机操控', '关闭后停止当前代码执行，并拒绝新的设备调用。')],
        ),
        if (message != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: MarketPanel(
              child: Text(
                message!,
                key: const ValueKey('engine-setup-message'),
                style: const TextStyle(height: 1.6),
              ),
            ),
          ),
        ProductSection(
          title: '日常操作',
          icon: Icons.touch_app_outlined,
          children: [
            toggle('system', '时钟与系统功能', '使用手机时钟、倒计时及支持的系统功能。'),
            toggle('control', '屏幕操作', '在你选择的软件中查看界面并操作。'),
            const Divider(),
            authorization(
              '无障碍服务',
              'accessibility',
              state['accessibility'] == true,
            ),
            authorization(
              '修改系统设置',
              'writeSettings',
              state['writeSettings'] == true,
            ),
          ],
        ),
        ProductSection(
          title: '屏幕识别',
          subtitle: '文字在手机上识别，操作后继续核对实际结果。',
          icon: Icons.document_scanner_outlined,
          children: [
            Wrap(
              key: const ValueKey('engine-recognition-mode'),
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final entry in const {
                  'auto': '自动选择',
                  'visual': '视觉优先',
                }.entries)
                  ChoiceChip(
                    label: Text(entry.value),
                    selected:
                        (state['recognitionMode'] == 'visual'
                            ? 'visual'
                            : 'auto') ==
                        entry.key,
                    onSelected: busy || state['localOcr'] == false
                        ? null
                        : (_) => update('recognitionMode', entry.key),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              state['localOcr'] == false
                  ? '当前系统使用控件操作；屏幕文字识别需要 Android 11 或以上。'
                  : state['recognitionMode'] == 'visual'
                  ? '直接识别屏幕文字并定位，适合控件不完整的页面。'
                  : '优先操作控件，找不到目标时补充屏幕文字识别。',
              style: const TextStyle(fontSize: 13, height: 1.5),
            ),
            const Divider(),
            SwitchListTile(
              key: const ValueKey('engine-fast-capture'),
              contentPadding: EdgeInsets.zero,
              title: const Text('高速识屏'),
              subtitle: Text(
                state['fastCaptureActive'] == true
                    ? '正在连续获取最新画面，可随时停止。'
                    : '适合连续操作，开启时需确认本次屏幕共享授权。',
              ),
              value: state['fastCaptureActive'] == true,
              onChanged:
                  busy ||
                      state['enabled'] != true ||
                      state['control'] != true ||
                      state['accessibility'] != true ||
                      state['fastCaptureSupported'] != true
                  ? null
                  : (enabled) => run(() async {
                      if (enabled) {
                        await deviceEngine.startFastCapture();
                      } else {
                        await deviceEngine.stopFastCapture();
                      }
                      final current = await deviceEngine.status();
                      if (mounted) setState(() => state = current);
                    }),
            ),
          ],
        ),
        MarketPanel(
          padding: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('允许操作的软件', style: Theme.of(context).textTheme.titleMedium),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('全部已安装应用'),
                  subtitle: const Text('启用后跟随实际已安装应用；关闭时使用下方选择范围。系统权限仍按实际授权。'),
                  value: state['allApplications'] == true,
                  onChanged: busy ? null : (v) => update('allApplications', v),
                ),
                const SizedBox(height: 6),
                Text(
                  '已选 ${(state['packages'] as List? ?? []).length} 个 · 共 ${apps.length} 个软件',
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  key: const ValueKey('engine-choose-apps'),
                  onPressed: busy ? null : chooseApps,
                  icon: const Icon(Icons.search),
                  label: const Text('搜索并选择软件'),
                ),
                TextButton(
                  onPressed: busy ? null : () => chooseApps(selectedOnly: true),
                  child: const Text('查看已选软件'),
                ),
                const SizedBox(height: 4),
                Text(
                  '界面观察、点击和系统接口只在所选范围内工作。代码执行单独授予 shell 权限，不受此列表限制。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: 16),
        MarketPanel(
          key: const ValueKey('engine-advanced-panel'),
          child: ExpansionTile(
            title: const Text(
              '高级能力',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              state['shell'] == true ? '代码执行已开启 · 管理无线连接' : '编程环境与无线连接',
              style: const TextStyle(fontSize: 12),
            ),
            tilePadding: EdgeInsets.zero,
            children: [
              toggle('shell', '代码执行', '允许执行 Android shell 代码，需要单独配对。'),
              ListTile(
                leading: const Icon(Icons.code),
                title: const Text('小云项目与编程环境'),
                subtitle: const Text('内置 Linux、旧项目迁移、成果和运行状态'),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const CloudCodingPage(),
                  ),
                ),
              ),
              ExpansionTile(
                key: const ValueKey('engine-wireless-panel'),
                title: const Text('代码执行 · 无线配对'),
                subtitle: Text(
                  state['shellConnected'] == true
                      ? '已连接 · UID ${state['shellUid']}'
                      : state['shellPaired'] == true
                      ? '已配对 · 等待连接'
                      : '未连接 · Android 11 及以上',
                ),
                childrenPadding: const EdgeInsets.all(12),
                children: [
                  const Text('推荐使用配对通知：保持系统配对窗口打开，在通知栏输入六位代码，无需切换回应用。'),
                  FilledButton.icon(
                    onPressed:
                        busy ||
                            state['enabled'] != true ||
                            state['shell'] != true
                        ? null
                        : () => run(() async {
                            final result = await deviceEngine
                                .startPairingNotification();
                            if (result['outcome'] == 'permission_required') {
                              await deviceEngine.openAuthorization(
                                'notifications',
                              );
                            }
                            if (mounted)
                              setState(
                                () => message = result['summary'] as String?,
                              );
                          }),
                    icon: const Icon(Icons.notifications_active_outlined),
                    label: const Text('开启配对通知'),
                  ),
                  const SizedBox(height: 12),
                  if (state['developerOptions'] != true)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 12),
                      child: Text(
                        '开发者选项尚未开启。先在“关于手机”连续点击版本号，完成系统验证，再返回开启无线调试。',
                      ),
                    ),
                  const Text(
                    '在系统开发者选项打开无线调试，选择“使用配对码配对设备”。首次需要在同一局域网中完成系统配对。重启或无线调试关闭后，返回这里核对连接。',
                  ),
                  TextButton.icon(
                    onPressed: busy
                        ? null
                        : () => run(() async {
                            await deviceEngine.openAuthorization(
                              'wirelessDebugging',
                            );
                          }),
                    icon: const Icon(Icons.settings_outlined),
                    label: const Text('打开系统无线调试设置'),
                  ),
                  const Text('以下手动输入适合分屏使用；切换应用可能会关闭系统配对端口。'),
                  const SizedBox(height: 8),
                  portField(pairPort, '配对窗口中的端口'),
                  portField(pairCode, '六位配对码', secret: true),
                  FilledButton(
                    onPressed:
                        busy ||
                            state['enabled'] != true ||
                            state['shell'] != true
                        ? null
                        : () => run(() async {
                            final result = await deviceEngine.pair(
                              port(pairPort),
                              pairCode.text,
                            );
                            pairCode.clear();
                            if (mounted)
                              setState(
                                () => message = result['summary'] as String?,
                              );
                          }),
                    child: const Text('完成系统配对'),
                  ),
                  const SizedBox(height: 16),
                  const Text('配对完成后，使用无线调试主页面“IP 地址和端口”中的连接端口。两个端口通常不同。'),
                  portField(connectPort, '无线调试连接端口'),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('已核对系统端口，信任本机调试证书'),
                    subtitle: const Text('首次连接或系统调试证书更新时需要。后续连接会校验已保存的证书公钥。'),
                    value: trustPeer,
                    onChanged: busy
                        ? null
                        : (v) => setState(() => trustPeer = v == true),
                  ),
                  FilledButton(
                    onPressed:
                        busy ||
                            state['enabled'] != true ||
                            state['shell'] != true
                        ? null
                        : () => run(() async {
                            await deviceEngine.connect(
                              port(connectPort),
                              trustPeer: trustPeer,
                            );
                            trustPeer = false;
                            final result = await deviceEngine.status();
                            if (mounted)
                              setState(() {
                                state = result;
                                message = '已核对真实 shell 身份。';
                              });
                          }),
                    child: const Text('连接并验证身份'),
                  ),
                  TextButton(
                    onPressed: () async {
                      await deviceEngine.disconnect();
                      if (mounted) refresh();
                    },
                    child: const Text('断开代码执行后端'),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        TextButton.icon(
          onPressed: () async {
            final result = await deviceEngine.stop();
            if (mounted) setState(() => message = result['summary'] as String?);
          },
          icon: const Icon(Icons.stop_circle_outlined),
          label: const Text('停止当前设备执行'),
        ),
      ],
    ),
  );
}

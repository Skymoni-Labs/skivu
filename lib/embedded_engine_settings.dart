import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'device_engine.dart';
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
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('内置手机引擎'),
      actions: [
        IconButton(
          onPressed: busy ? null : refresh,
          tooltip: '核对授权状态',
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 36),
      children: [
        const Padding(
          padding: EdgeInsets.all(12),
          child: Text('小云、插件与手机 DSH 共用这套能力。按需开启权限；系统授权与应用范围由你管理。'),
        ),
        SizedBox(
          height: 4,
          child: busy ? const LinearProgressIndicator() : null,
        ),
        if (message != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(message!, key: const ValueKey('engine-setup-message')),
          ),
        toggle('enabled', '启用手机引擎', '关闭后拒绝设备调用，并停止当前代码执行。'),
        toggle('system', '系统接口', '手机时钟、倒计时及受支持的系统设置。'),
        toggle('control', '界面操控', '仅操作下方选中的软件，需要无障碍授权。'),
        toggle('shell', '代码执行', '允许执行具备 Android shell 权限的代码，需要单独配对。'),
        const Divider(),
        authorization('无障碍服务', 'accessibility', state['accessibility'] == true),
        authorization(
          '修改系统设置',
          'writeSettings',
          state['writeSettings'] == true,
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
                  busy || state['enabled'] != true || state['shell'] != true
                  ? null
                  : () => run(() async {
                      final result = await deviceEngine
                          .startPairingNotification();
                      if (result['outcome'] == 'permission_required') {
                        await deviceEngine.openAuthorization('notifications');
                      }
                      if (mounted)
                        setState(() => message = result['summary'] as String?);
                    }),
              icon: const Icon(Icons.notifications_active_outlined),
              label: const Text('开启配对通知'),
            ),
            const SizedBox(height: 12),
            if (state['developerOptions'] != true)
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: Text('开发者选项尚未开启。先在“关于手机”连续点击版本号，完成系统验证，再返回开启无线调试。'),
              ),
            const Text(
              '在系统开发者选项打开无线调试，选择“使用配对码配对设备”。首次需要在同一局域网中完成系统配对。重启或无线调试关闭后，返回这里核对连接。',
            ),
            TextButton.icon(
              onPressed: busy
                  ? null
                  : () => run(() async {
                      await deviceEngine.openAuthorization('wirelessDebugging');
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
                  busy || state['enabled'] != true || state['shell'] != true
                  ? null
                  : () => run(() async {
                      final result = await deviceEngine.pair(
                        port(pairPort),
                        pairCode.text,
                      );
                      pairCode.clear();
                      if (mounted)
                        setState(() => message = result['summary'] as String?);
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
                  busy || state['enabled'] != true || state['shell'] != true
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
        const Divider(),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('允许操作的软件', style: Theme.of(context).textTheme.titleMedium),
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

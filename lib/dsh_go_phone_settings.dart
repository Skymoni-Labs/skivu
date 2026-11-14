import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dsh_go_phone_check.dart';
import 'product_ui.dart';
import 'cloud_coding_page.dart';
import 'engine_app_selection_page.dart';
import 'state.dart' show demo;

VoidCallback? openDshGoPhoneSettings;
bool dshGoPhoneSettingsPending = false;
void requestDshGoPhoneSettings() {
  if (openDshGoPhoneSettings != null) {
    openDshGoPhoneSettings!();
  } else {
    dshGoPhoneSettingsPending = true;
  }
}

/// Skivu presentation for the original dsh-go PhonePlugin. Models never receive
/// this settings channel. All persisted settings and gates belong to that plugin.
class DshGoPhoneSettings extends StatefulWidget {
  const DshGoPhoneSettings({super.key});
  @override
  State<DshGoPhoneSettings> createState() => _DshGoPhoneSettingsState();
}

class _DshGoPhoneSettingsState extends State<DshGoPhoneSettings>
    with WidgetsBindingObserver {
  static const channel = MethodChannel('dsh/phone');
  static const events = EventChannel('dsh/phone/events');
  StreamSubscription<dynamic>? subscription;
  Map state = {}, policies = {}, shell = {}, overlay = {};
  bool busy = false;
  int loadEpoch = 0;
  String? error;
  Map map(dynamic value) => value is Map ? value : const {};
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    subscription = events.receiveBroadcastStream().listen(
      (value) {
        if (mounted && value is Map) setState(() => acceptState(value));
      },
      onError: (Object e) {
        if (mounted) setState(() => error = '$e');
      },
    );
    unawaited(load());
  }

  @override
  void dispose() {
    subscription?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState value) {
    if (value == AppLifecycleState.resumed && !busy) unawaited(load());
  }

  Future<void> load() async {
    final epoch = ++loadEpoch;
    try {
      final values = await Future.wait([
        channel.invokeMapMethod('status'),
        channel.invokeMapMethod('getPolicies'),
        channel.invokeMapMethod('androidShellStatus'),
        channel.invokeMapMethod('overlayPrefs'),
      ]);
      if (mounted && epoch == loadEpoch)
        setState(() {
          acceptState(values[0] ?? {});
          policies = values[1] ?? {};
          shell = values[2] ?? {};
          overlay = values[3] ?? {};
        });
    } catch (e) {
      if (mounted)
        setState(() => error = e is PlatformException ? e.message : '$e');
    }
  }

  Future<dynamic> run(String method, [Map? args]) async {
    if (busy) return null;
    loadEpoch++;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await channel.invokeMethod<dynamic>(method, args);
      if (result == false || result is Map && result['ok'] == false) {
        throw StateError(
          result is Map
              ? '${result['reason'] ?? result['errorCode'] ?? '设置未保存'}'
              : '设置未保存，请检查当前任务状态。',
        );
      }
      await load();
      return result;
    } catch (e) {
      if (mounted)
        setState(() => error = e is PlatformException ? e.message : '$e');
      return null;
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void acceptState(Map value) {
    final before = state['statusRevision'], after = value['statusRevision'];
    if (before is num && after is num && after < before) return;
    state = value;
  }

  Widget section(
    String title,
    List<Widget> children, {
    String? subtitle,
    IconData? icon,
  }) => ProductSection(
    title: title,
    subtitle: subtitle,
    icon: icon,
    children: children,
  );
  Widget action(String title, String method, {Map? args, String? subtitle}) =>
      ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(title),
        subtitle: subtitle == null ? null : Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: busy ? null : () => run(method, args),
      );
  Widget toggle(
    String title,
    bool value,
    String method,
    Map Function(bool) args, {
    String? subtitle,
  }) => SwitchListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(title),
    subtitle: subtitle == null ? null : Text(subtitle),
    value: value,
    onChanged: busy ? null : (v) => run(method, args(v)),
  );
  Future<void> textResult(String title, String method, [Map? args]) async {
    final value = await run(method, args);
    if (!mounted || value == null) return;
    final text = value is Map
        ? '${value['text'] ?? value['summary'] ?? value['reason'] ?? value['state'] ?? value['kind'] ?? '操作已返回，请查看任务状态。'}'
        : value is List
        ? value
              .whereType<Map>()
              .map(
                (e) =>
                    '${e['sentence'] ?? e['summary'] ?? e['action'] ?? e['text'] ?? ''}',
              )
              .where((e) => e.isNotEmpty)
              .join('\n')
        : '$value';
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: SelectableText(text)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> pair({bool androidShell = false}) async {
    final code = TextEditingController(), port = TextEditingController();
    final route = DialogRoute<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('无线调试配对'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('保持系统的配对窗口打开，填写窗口中的配对码和端口。'),
              TextField(
                controller: code,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(6),
                ],
                decoration: const InputDecoration(labelText: '配对码'),
              ),
              TextField(
                controller: port,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(5),
                ],
                decoration: const InputDecoration(labelText: '配对端口（可留空自动发现）'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('配对'),
          ),
        ],
      ),
    );
    final ok = await Navigator.of(context, rootNavigator: true).push(route);
    await route.completed;
    final enteredCode = code.text.trim(), enteredPort = port.text.trim();
    code.dispose();
    port.dispose();
    if (ok == true)
      await run(androidShell ? 'androidShellPair' : 'adbPair', {
        'code': enteredCode,
        if (enteredPort.isNotEmpty) 'port': int.tryParse(enteredPort),
      });
  }

  Future<void> rules(String key, String title) async {
    final listed = await run('policyApps');
    if (!mounted || listed is! List) return;
    final apps = listed
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    final selected = Set<String>.from(policies[key] as List? ?? []);
    final known = apps.map((e) => e['package']).toSet();
    for (final package in selected.difference(known)) {
      apps.add({
        'package': package,
        'name': map(policies['labels'])[package] ?? package,
      });
    }
    final excluded = key == 'denyPackages';
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => EngineAppSelectionPage(
          title: title,
          prompt: excluded ? '选择小云不读取、不操作的软件' : '选择每次操作前都需要你确认的软件',
          selectedDescription: excluded ? '已排除，小云不能读取或操作' : '每次操作前都会询问你',
          unselectedDescription: excluded ? '未排除，仍受其他权限和规则限制' : '使用手机操控的默认确认方式',
          apps: apps,
          selected: selected,
          editManually: (packages) async {
            final controller = TextEditingController(text: packages.join('\n'));
            final route = DialogRoute<bool>(
              context: context,
              builder: (c) => AlertDialog(
                title: Text('手动编辑$title'),
                content: SingleChildScrollView(
                  child: TextField(
                    controller: controller,
                    minLines: 3,
                    maxLines: 7,
                    decoration: const InputDecoration(
                      labelText: '每行一个应用包名',
                      helperText: '可保留未安装或没有桌面入口的软件规则。',
                    ),
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(c, false),
                    child: const Text('取消'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(c, true),
                    child: const Text('保存'),
                  ),
                ],
              ),
            );
            final approved = await Navigator.of(
              context,
              rootNavigator: true,
            ).push(route);
            await route.completed;
            final entered = controller.text
                .split(RegExp(r'[\s,;]+'))
                .where((e) => e.isNotEmpty)
                .toSet();
            controller.dispose();
            if (approved != true) return null;
            final saved = await run('setPolicies', {key: entered.toList()});
            if (saved == null)
              throw PlatformException(
                code: 'PHONE_POLICY_SAVE',
                message: error ?? '保存未完成，请重试。',
              );
            return Set<String>.from(policies[key] as List? ?? []);
          },
          save: (packages) async {
            final saved = await run('setPolicies', {key: packages.toList()});
            if (saved == null)
              throw PlatformException(
                code: 'PHONE_POLICY_SAVE',
                message: error ?? '保存未完成，请重试。',
              );
            return Set<String>.from(policies[key] as List? ?? []);
          },
        ),
      ),
    );
  }

  Widget choices<T>(
    String title,
    T selected,
    Map<T, String> options,
    ValueChanged<T> change, {
    String? subtitle,
    Key? key,
  }) => Padding(
    key: key,
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        ),
        if (subtitle != null)
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: Text(
              subtitle,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(height: 1.5),
            ),
          ),
        const SizedBox(height: 9),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            for (final entry in options.entries)
              ChoiceChip(
                label: Text(entry.value),
                selected: selected == entry.key,
                onSelected: busy ? null : (_) => change(entry.key),
              ),
          ],
        ),
      ],
    ),
  );

  Future<void> unlock(String key, String title, bool enabled) async {
    var approved = !enabled;
    if (enabled) {
      approved =
          await showDialog<bool>(
            context: context,
            builder: (c) => AlertDialog(
              title: Text('允许$title'),
              content: Text(
                '开启后，AI 可以操作$title。页面内容可能诱导错误操作；这可能影响权限、账号或隐私。只有你明确需要时才开启，可随时在此关闭。',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(c, false),
                  child: const Text('取消'),
                ),
                _HoldPhoneConfirm(onConfirmed: () => Navigator.pop(c, true)),
              ],
            ),
          ) ??
          false;
    }
    if (approved)
      await run('setPolicies', {
        'unlocks': {key: enabled},
      });
  }

  @override
  Widget build(BuildContext context) {
    final a11y = map(state['a11y']);
    final background = map(state['background']);
    final privileged = map(background['privileged']);
    final keep = map(privileged['keep']);
    const modes = {
      'off': '主屏操作',
      'shizuku': 'Shizuku',
      'sui': 'Sui',
      'root': 'Root',
      'adb': '无线调试',
    };
    final configuredMode =
        '${privileged['mode'] ?? background['mode'] ?? 'off'}';
    final mode = modes.containsKey(configuredMode) ? configuredMode : 'off';
    final ready = privileged['ready'] == true;
    final tasks = (state['tasks'] as List? ?? []).whereType<Map>().where((
      task,
    ) {
      final id = task['taskId'] ?? task['id'];
      return id is num &&
          id > 0; // Native id 0 is the idle placeholder, not a task.
    });
    final interruption = map(state['taskInterruption']);
    final confirm = const {'ask': '每次询问', 'task': '按任务确认', 'always': '普通操作免确认'};
    final confirmMode = confirm.containsKey(policies['confirmMode'])
        ? policies['confirmMode'] as String
        : 'ask';
    final theme = Theme.of(context);
    return Theme(
      data: theme.copyWith(
        appBarTheme: theme.appBarTheme.copyWith(
          foregroundColor: demo.dark
              ? const Color(0xffeef3fc)
              : theme.colorScheme.onSurface,
        ),
      ),
      child: ProductScaffold(
        title: '手机操控',
        actions: [
          IconButton(
            onPressed: busy ? null : load,
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新设备状态',
          ),
        ],
        body: ListTileTheme(
          data: ListTileThemeData(
            contentPadding: EdgeInsets.zero,
            titleTextStyle: TextStyle(
              color: Theme.of(context).colorScheme.onSurface,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
            subtitleTextStyle: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 12,
              height: 1.5,
            ),
          ),
          child: ListView(
            key: const ValueKey('skivu-phone-settings'),
            padding: const EdgeInsets.all(18),
            children: [
              if (busy)
                const Padding(
                  padding: EdgeInsets.only(bottom: 12),
                  child: LinearProgressIndicator(minHeight: 2),
                ),
              section(
                state['enabled'] == true ? '手机操控已开启' : '开启手机操控',
                [
                  toggle(
                    '允许手机操控',
                    state['enabled'] == true,
                    'setEnabled',
                    (v) => {'enabled': v},
                    subtitle: '让小云查看界面并操作，随时可以暂停或停止。',
                  ),
                ],
                subtitle: '把手机上的事情交给小云，由你决定操作范围和确认方式。',
                icon: Icons.phonelink_setup_rounded,
              ),
              if (error != null)
                ProductError(
                  message: '本次设置或连接未完成',
                  detail: error!,
                  onRetry: busy ? null : load,
                ),
              if ((interruption['count'] as num? ?? 0) > 0 ||
                  interruption['state'] == 'error')
                section('上次手机任务中断', [
                  const Text(
                    '操作结果可能已经发生。请核对实际软件中的状态；确认此提示不会重新执行任务。',
                    style: TextStyle(fontSize: 13, height: 1.6),
                  ),
                  if (interruption['batchToken'] is String)
                    action(
                      '我已核对中断任务',
                      'acknowledgeTaskInterruption',
                      args: {'batchToken': interruption['batchToken']},
                    ),
                  if (interruption['state'] == 'error')
                    action('重试读取或保存状态', 'retryTaskInterruptionStorage'),
                ], icon: Icons.info_outline_rounded),
              section('日常操作', [
                action(
                  '无障碍服务',
                  'openAccessibilitySettings',
                  subtitle: a11y['serviceConnected'] == true
                      ? '已连接，可以查看并操作界面'
                      : a11y['enabled'] == true
                      ? '已开启，等待系统连接'
                      : '尚未开启 · 前往系统设置授权',
                ),
                const Divider(height: 20),
                action(
                  '通知与应用权限',
                  'openAppDetails',
                  subtitle: state['notifications'] == true
                      ? '通知已允许，可接收任务和确认提示'
                      : '尚未允许任务通知',
                ),
                const Divider(height: 20),
                choices<String>(
                  '操作前如何确认',
                  confirmMode,
                  confirm,
                  (v) => run('setPolicies', {'confirmMode': v}),
                  key: const ValueKey('phone-confirm-mode'),
                  subtitle: '敏感软件和特殊操作仍遵循单独的规则。',
                ),
              ], icon: Icons.touch_app_outlined),
              section(
                '屏幕识别',
                [
                  toggle(
                    '本地文字识别',
                    policies['localOcrEnabled'] == true,
                    'setPolicies',
                    (v) => {'localOcrEnabled': v},
                    subtitle: '控件文字不足时补充识别，操作后继续核对实际结果。',
                  ),
                  const Divider(height: 20),
                  ListTile(
                    title: const Text('检查当前屏幕文字'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: busy ? null : () => textResult('当前屏幕', 'testScreen'),
                  ),
                ],
                subtitle: '优先读取可操作控件，文字识别在手机本地完成。',
                icon: Icons.document_scanner_outlined,
              ),
              section(
                '不打扰模式',
                [
                  choices<String>(
                    '操作方式与连接',
                    mode,
                    modes,
                    (v) => run('setBackgroundMode', {'mode': v}),
                    key: const ValueKey('phone-background-mode'),
                    subtitle: mode == 'off'
                        ? '当前使用主屏；后台操作需要先选择并授权连接方式。'
                        : ready
                        ? '后台连接已就绪，具体应用支持情况以实际检查为准。'
                        : '已选择 ${modes[mode]}，请先完成连接与授权。',
                  ),
                  if (mode == 'shizuku' || mode == 'sui')
                    action('请求连接授权', 'requestShizukuPermission'),
                  if (mode == 'root') action('请求 Root 连接', 'prepareRoot'),
                  if (mode == 'adb')
                    ExpansionTile(
                      key: const PageStorageKey('phone-wireless-panel'),
                      tilePadding: EdgeInsets.zero,
                      title: const Text('无线配对与连接'),
                      subtitle: const Text('配对通知、输入配对码和连接'),
                      children: [
                        const Text(
                          '先在系统开发者选项中开启无线调试，并保持配对窗口打开。',
                          style: TextStyle(fontSize: 13, height: 1.6),
                        ),
                        action('开启配对通知', 'adbStartPairing'),
                        ListTile(
                          title: const Text('填写无线配对码'),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          onTap: busy ? null : () => pair(),
                        ),
                        action('连接无线调试', 'adbConnect'),
                      ],
                    ),
                  if (mode != 'off') ...[
                    toggle(
                      '保持授权连接',
                      keep['enabled'] == true,
                      'setBackgroundKeep',
                      (v) => {'mode': mode, 'enabled': v},
                      subtitle: '按当前授权方式保持连接，关闭后仍可手动连接。',
                    ),
                    if (privileged['reason'] != null && !ready)
                      ExpansionTile(
                        key: const PageStorageKey('phone-background-details'),
                        tilePadding: EdgeInsets.zero,
                        title: const Text('查看连接详情'),
                        children: [
                          Align(
                            alignment: Alignment.centerLeft,
                            child: SelectableText(
                              '${privileged['reason']}',
                              style: const TextStyle(fontSize: 12, height: 1.6),
                            ),
                          ),
                        ],
                      ),
                  ],
                  ListTile(
                    title: const Text('检查手机操控环境'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: busy
                        ? null
                        : () => showDialog<void>(
                            context: context,
                            barrierDismissible: false,
                            builder: (_) => const DshGoPhoneCheck(),
                          ),
                  ),
                ],
                subtitle: '授权后可在独立后台屏操作受支持的应用，需要 Android 14 或以上。',
                icon: Icons.do_not_disturb_on_outlined,
              ),
              section(
                '应用规则',
                [
                  ListTile(
                    key: const ValueKey('phone-excluded-apps'),
                    title: const Text('不允许操作的软件'),
                    subtitle: Text(
                      '已排除 ${(policies['denyPackages'] as List? ?? []).length} 个 · 搜索并选择软件',
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: busy
                        ? null
                        : () => rules('denyPackages', '不允许操作的软件'),
                  ),
                  const Divider(height: 20),
                  ListTile(
                    title: const Text('每次操作都要确认的软件'),
                    subtitle: Text(
                      '已设置 ${(policies['confirmEveryWritePackages'] as List? ?? []).length} 个',
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: busy
                        ? null
                        : () =>
                              rules('confirmEveryWritePackages', '每次操作都要确认的软件'),
                  ),
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    key: const PageStorageKey('phone-sensitive-panel'),
                    title: const Text('敏感操作设置'),
                    subtitle: const Text('系统权限页面、密码字段和 Skivu 自身'),
                    children: [
                      for (final entry in const {
                        'systemPages': '系统设置和权限页面',
                        'secretFields': '密码和验证码字段',
                        'ownApp': 'Skivu 自身',
                      }.entries)
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text('允许操作${entry.value}'),
                          value: map(policies['unlocks'])[entry.key] == true,
                          onChanged: busy
                              ? null
                              : (v) => unlock(entry.key, entry.value, v),
                        ),
                    ],
                  ),
                ],
                subtitle: '为不同软件单独设置排除范围和确认要求。',
                icon: Icons.shield_outlined,
              ),
              if (tasks.isNotEmpty)
                section('手机任务', [
                  for (final task in tasks)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        ListTile(
                          title: Text(
                            '手机任务 ${task['taskId'] ?? task['id'] ?? ''}',
                          ),
                          subtitle: Text(
                            task['finishing'] == true ||
                                    task['draining'] == true
                                ? '正在结束并释放资源'
                                : task['stopped'] == true
                                ? '已停止'
                                : task['paused'] == true
                                ? '已暂停'
                                : programStateLabel(
                                    task['status'] ??
                                        task['phase'] ??
                                        (task['active'] == true
                                            ? 'running'
                                            : 'unknown'),
                                  ),
                          ),
                        ),
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          children: [
                            TextButton.icon(
                              icon: const Icon(Icons.pause_rounded),
                              label: const Text('暂停'),
                              onPressed: busy
                                  ? null
                                  : () => run('pauseTask', {
                                      'taskId': task['taskId'] ?? task['id'],
                                      'paused': true,
                                    }),
                            ),
                            TextButton.icon(
                              icon: const Icon(Icons.play_arrow_rounded),
                              label: const Text('继续'),
                              onPressed: busy
                                  ? null
                                  : () => run('resumeTask', {
                                      'taskId': task['taskId'] ?? task['id'],
                                    }),
                            ),
                            TextButton.icon(
                              icon: const Icon(Icons.stop_circle_outlined),
                              label: const Text('停止'),
                              onPressed: busy
                                  ? null
                                  : () => run('stopTask', {
                                      'taskId': task['taskId'] ?? task['id'],
                                    }),
                            ),
                            if (task['cleanupFailed'] == true)
                              TextButton.icon(
                                icon: const Icon(Icons.refresh_rounded),
                                label: const Text('重试释放资源'),
                                onPressed: busy
                                    ? null
                                    : () => run('retryTaskCleanup', {
                                        'taskId': task['taskId'] ?? task['id'],
                                      }),
                              ),
                          ],
                        ),
                      ],
                    ),
                ], icon: Icons.task_alt_rounded),
              MarketPanel(
                child: ExpansionTile(
                  key: const PageStorageKey('phone-advanced-panel'),
                  tilePadding: EdgeInsets.zero,
                  title: const Text(
                    '高级能力',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  subtitle: const Text(
                    '编程环境、Android Shell 与后台屏设置',
                    style: TextStyle(fontSize: 12),
                  ),
                  children: [
                    ListTile(
                      leading: const Icon(Icons.code_rounded),
                      title: const Text('小云项目与编程环境'),
                      subtitle: const Text('内置 Linux、项目、成果和运行状态'),
                      onTap: busy
                          ? null
                          : () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => const CloudCodingPage(),
                              ),
                            ),
                    ),
                    const Divider(height: 20),
                    toggle(
                      '允许 Android Shell',
                      shell['enabled'] == true,
                      'configureAndroidShell',
                      (v) => {
                        'enabled': v,
                        'backend': shell['backend'] == 'adb'
                            ? 'adb'
                            : 'shizuku',
                      },
                      subtitle: '手机系统命令单独授权；小云内置编程不依赖此开关。',
                    ),
                    choices<String>(
                      'Shell 连接方式',
                      shell['backend'] == 'adb' ? 'adb' : 'shizuku',
                      const {'shizuku': 'Shizuku', 'adb': '无线调试'},
                      (v) => run('configureAndroidShell', {
                        'enabled': shell['enabled'] == true,
                        'backend': v,
                      }),
                    ),
                    action('请求 Shell 授权', 'androidShellRequestPermission'),
                    action('开启 Shell 配对通知', 'androidShellStartPairing'),
                    ListTile(
                      title: const Text('填写 Shell 配对码'),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: busy ? null : () => pair(androidShell: true),
                    ),
                    action('连接 Shell', 'androidShellConnect'),
                    action('停止 Shell 命令', 'androidShellStop'),
                    const Divider(height: 20),
                    action('允许恢复无障碍服务', 'grantSecureSettings'),
                    toggle(
                      '显示后台预览',
                      map(background['preview'])['enabled'] == true,
                      'setBackgroundPreview',
                      (v) => {'enabled': v},
                    ),
                    choices<String>(
                      '后台屏方向',
                      map(background['viewport'])['preset'] == 'landscape'
                          ? 'landscape'
                          : 'portrait',
                      const {'portrait': '竖屏', 'landscape': '横屏'},
                      (v) => run('setBackgroundViewport', {'preset': v}),
                    ),
                    choices<int>(
                      '并行后台任务',
                      (map(background['parallelism'])['configuredLimit']
                                  as num? ??
                              1)
                          .toInt()
                          .clamp(1, 3),
                      const {1: '1 个任务', 2: '2 个任务', 3: '3 个任务'},
                      (v) => run('setBackgroundParallelLimit', {'limit': v}),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              MarketPanel(
                child: ExpansionTile(
                  key: const PageStorageKey('phone-overlay-panel'),
                  tilePadding: EdgeInsets.zero,
                  title: const Text(
                    '悬浮条和记录',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  subtitle: const Text(
                    '悬浮条外观与本次运行记录',
                    style: TextStyle(fontSize: 12),
                  ),
                  children: [
                    toggle(
                      '空闲时自动收起悬浮条',
                      overlay['autoCollapse'] == true,
                      'setOverlayPrefs',
                      (v) => {'autoCollapse': v},
                    ),
                    ListTile(
                      title: const Text('空闲透明度'),
                      subtitle: Slider(
                        value: (overlay['idleOpacity'] as num? ?? 0.8)
                            .toDouble()
                            .clamp(.3, 1),
                        min: .3,
                        max: 1,
                        divisions: 7,
                        onChanged: busy
                            ? null
                            : (v) => run('setOverlayPrefs', {'idleOpacity': v}),
                      ),
                    ),
                    ListTile(
                      title: const Text('本次运行的操作记录'),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: busy
                          ? null
                          : () =>
                                textResult('操作记录', 'actionLog', {'limit': 100}),
                    ),
                    toggle(
                      '任务结束后提示保存路线',
                      map(state['skills'])['askAfterSuccess'] == true,
                      'setSkillSavePrompt',
                      (v) => {'enabled': v},
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              ListTile(
                leading: const Icon(Icons.info_outline_rounded),
                title: const Text('开源来源与许可'),
                subtitle: const Text('手机操控模块及其许可说明'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () =>
                    showLicensePage(context: context, applicationName: 'Skivu'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HoldPhoneConfirm extends StatefulWidget {
  const _HoldPhoneConfirm({required this.onConfirmed});
  final VoidCallback onConfirmed;
  @override
  State<_HoldPhoneConfirm> createState() => _HoldPhoneConfirmState();
}

class _HoldPhoneConfirmState extends State<_HoldPhoneConfirm> {
  Timer? timer;
  bool holding = false;
  void start() {
    timer?.cancel();
    setState(() => holding = true);
    timer = Timer(const Duration(milliseconds: 1500), widget.onConfirmed);
  }

  void stop() {
    timer?.cancel();
    if (mounted) setState(() => holding = false);
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
    onKeyEvent: (_, event) {
      if (event.logicalKey != LogicalKeyboardKey.space &&
          event.logicalKey != LogicalKeyboardKey.enter)
        return KeyEventResult.ignored;
      if (event is KeyDownEvent)
        start();
      else if (event is KeyUpEvent)
        stop();
      return KeyEventResult.handled;
    },
    child: Listener(
      onPointerDown: (_) => start(),
      onPointerUp: (_) => stop(),
      onPointerCancel: (_) => stop(),
      child: FilledButton(
        onPressed: () {},
        child: Text(holding ? '保持按住…' : '按住 1.5 秒确认'),
      ),
    ),
  );
}

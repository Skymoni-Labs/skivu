import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'open_plugin.dart';
import 'open_plugin_page.dart';
import 'state.dart';

Future<void> launchCloudPurge(
  BuildContext context,
  OpenPluginRegistry registry,
) async {
  try {
    var record = registry.records['org.skivu.purge'];
    if (record == null) {
      final source = await rootBundle.loadString(
        'assets/plugins/skivu-purge.skivu.json',
      );
      await registry.install(
        OpenPluginPackage.parse(source),
        origin: '随 Skivu 内置 · 原作 YuJunZhiXue/dsh-purge',
      );
      record = registry.records['org.skivu.purge'];
    }
    if (record != null && context.mounted) {
      await launchOpenPlugin(
        context,
        record,
        registry: registry,
        roleId: cloudPersonaId,
      );
    }
  } catch (e) {
    if (context.mounted)
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('提示词注入打开失败：$e')));
  }
}

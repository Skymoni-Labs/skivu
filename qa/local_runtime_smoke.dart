// Debug entrypoint for the real host transport. No fixed model responses.
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ski/open_plugin.dart';
import 'package:ski/open_plugin_page.dart';
import 'package:ski/relay_account.dart';
import 'package:ski/state.dart';
import 'package:ski/workspace.dart';

Future<void> main() async {
  if (!kDebugMode || !const bool.fromEnvironment('SKIVU_RUNTIME_QA')) {
    throw StateError('Runtime smoke entrypoint is debug-only');
  }
  WidgetsFlutterBinding.ensureInitialized();
  final dir = await getApplicationSupportDirectory();
  final accountFile = File('${dir.path}/qa-app-account.json');
  if (await accountFile.exists()) {
    final data = await accountFile.readAsString();
    await accountFile.delete();
    await const FlutterSecureStorage().write(
      key: 'skivu.relay.account.v1',
      value: data,
    );
  }
  await relayAccount.restore();
  if (relayAccount.signedIn) await relayAccount.refresh();
  demo.useAccount = true;
  final file = File('${dir.path}/qa-plugin.skivu.json');
  final package = OpenPluginPackage.parse(await file.readAsString());
  await openPlugins.install(package);
  await openPlugins.setEnabled(package.manifest.id, true);
  runApp(
    MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Skivu 本地运行验收')),
        body: WorkspacePanel(
          close: () {},
          launch: (context, record) => launchOpenPlugin(context, record),
        ),
      ),
    ),
  );
}

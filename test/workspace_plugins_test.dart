import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ski/open_plugin.dart';
import 'package:ski/open_plugin_page.dart';
import 'package:ski/workspace.dart';

import 'open_plugin_test.dart' as fixtures;

OpenPluginPackage workspacePackage(
  String id,
  String name, {
  bool launcher = true,
}) {
  final value =
      jsonDecode(fixtures.package(id: id).raw) as Map<String, dynamic>;
  value['manifest']['name'] = name;
  value['manifest']['contributes']['launcher'] = launcher;
  return OpenPluginPackage.parse(jsonEncode(value));
}

void main() {
  testWidgets(
    'workspace lists only authorized launcher plugins and reacts to revocation',
    (tester) async {
      final library = OpenPluginRegistry();
      final active = workspacePackage('test.active', 'Active plugin');
      final inactive = workspacePackage('test.inactive', 'Disabled plugin');
      final wrongDigest = workspacePackage('test.changed', 'Changed plugin');
      final noLauncher = workspacePackage(
        'test.hidden',
        'No launcher',
        launcher: false,
      );
      library.records[active.manifest.id] = OpenPluginRecord(
        active,
        enabled: true,
        grantedDigest: active.digest,
      );
      library.records[inactive.manifest.id] = OpenPluginRecord(inactive);
      library.records[wrongDigest.manifest.id] = OpenPluginRecord(
        wrongDigest,
        enabled: true,
        grantedDigest: 'old',
      );
      library.records[noLauncher.manifest.id] = OpenPluginRecord(
        noLauncher,
        enabled: true,
        grantedDigest: noLauncher.digest,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WorkspacePanel(close: () {}, registry: library),
          ),
        ),
      );
      expect(find.text('Active plugin'), findsOneWidget);
      expect(find.text('Disabled plugin'), findsNothing);
      expect(find.text('Changed plugin'), findsNothing);
      expect(find.text('No launcher'), findsNothing);
      await tester.ensureVisible(find.text('Active plugin'));
      await tester.tap(find.text('Active plugin'));
      await tester.pumpAndSettle();
      expect(find.byType(OpenPluginPage), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      library.records[active.manifest.id]!.enabled = false;
      library.storageChanged(active.manifest.id);
      await tester.pump();
      expect(find.text('Active plugin'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      library.dispose();
    },
  );
}

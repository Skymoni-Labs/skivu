import 'package:flutter/foundation.dart';
import 'cloud_coding_tools.dart';
import 'open_plugin.dart';

/// Old launcher removal follows verified, additive migration. Failure keeps its
/// existing data/route available; the built-in environment remains independent.
final cloudIntegration = CloudIntegration();

class CloudIntegration extends ChangeNotifier {
  bool migrated = false;
  Future<void> initialize() async {
    try {
      final result = await cloudExecutionChannel
          .invokeMapMethod<String, dynamic>('migration');
      final next = const {'verified', 'not_present'}.contains(result?['state']);
      if (next && openPlugins.records['org.skivu.dsh']?.enabled == true)
        await openPlugins.setEnabled('org.skivu.dsh', false);
      if (next != migrated) {
        migrated = next;
        notifyListeners();
      }
    } catch (_) {}
  }
}

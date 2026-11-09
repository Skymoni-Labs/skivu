import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'model_connection.dart';
import 'state.dart';

Object? _canonical(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final k in keys) k: _canonical(value[k])};
  }
  if (value is List) return value.map(_canonical).toList();
  return value;
}

Map<String, dynamic> modelAuthority(Map<String, dynamic> config) => {
  for (final key in [
    'id',
    'protocol',
    'address',
    'model',
    'auth',
    'credentialId',
  ])
    if (config.containsKey(key)) key: config[key],
};
String modelBindingFingerprint(Map<String, dynamic> binding) => sha256
    .convert(
      utf8.encode(
        jsonEncode(
          _canonical({
            ...binding,
            if (binding['connection'] is Map)
              'connection': modelAuthority(
                Map<String, dynamic>.from(binding['connection']),
              ),
          }),
        ),
      ),
    )
    .toString();

/// Public model configuration only, never a credential/token. Ordinary chat's
/// model selection does not change a previously saved plan's model.
Map<String, dynamic> scheduledModelBinding(DemoStore store) => {
  'kind': store.useBeta
      ? 'beta'
      : store.useAccount
      ? 'account'
      : 'connection',
  'connection': store.activeConnection?.toJson(),
  if (store.useAccount || store.useBeta) ...{
    'funding': store.account.funding,
    'user': store.account.user?['id'],
  },
};
String scheduledModelIdentity(DemoStore store) =>
    modelBindingFingerprint(scheduledModelBinding(store));

ModelConnection? resolveScheduledModel(
  DemoStore store,
  Map<String, dynamic> binding,
) {
  if (binding['connection'] is! Map) return null;
  final saved = ModelConnection.fromJson(
    Map<String, dynamic>.from(binding['connection']),
  );
  if (binding['kind'] == 'connection') {
    final actual = store.models.connections
        .where((c) => c.id == saved.id)
        .firstOrNull;
    if (actual == null ||
        modelBindingFingerprint({...binding, 'connection': actual.toJson()}) !=
            modelBindingFingerprint(binding))
      return null;
    return actual;
  }
  if (binding['kind'] == 'account') {
    if (!store.account.signedIn ||
        store.account.user?['id'] != binding['user'] ||
        store.account.funding != binding['funding'] ||
        !store.account.models.contains(saved.model) ||
        store.account.protocols[saved.model] !=
            (saved.protocol.name == 'chat' ? 'chat' : 'responses'))
      return null;
    return saved;
  }
  if (binding['kind'] == 'beta' && store.beta.enrolled) return saved;
  return null;
}

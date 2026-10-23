import 'dart:convert';

/// Local role-chat attachments, never executable HTML or a model credential.
Map<String, dynamic>? cleanChatInteraction(Map<dynamic, dynamic> raw) {
  final id = raw['id'], kind = raw['kind'], payload = raw['payload'];
  final created = DateTime.tryParse(
    raw['created'] is String ? raw['created'] : '',
  );
  if (id is! String ||
      id.length < 8 ||
      id.length > 100 ||
      created == null ||
      payload is! Map)
    return null;
  final p = <String, dynamic>{};
  String? text(String key, int limit) {
    final v = payload[key];
    return v is String && v.length <= limit ? v : null;
  }

  if (['image', 'video', 'audio', 'file', 'music'].contains(kind)) {
    final data = text('data', 2800000), name = text('name', 120);
    if (data == null || name == null || name.trim().isEmpty) return null;
    final match = RegExp(
      r'^data:([a-z0-9.+/-]+);base64,([A-Za-z0-9+/=]+)$',
    ).firstMatch(data);
    if (match == null) return null;
    final mime = match.group(1)!;
    final allowed = switch (kind) {
      'image' => ['image/png', 'image/jpeg', 'image/webp'],
      'video' => ['video/mp4', 'video/webm'],
      'audio' || 'music' => [
        'audio/webm',
        'audio/ogg',
        'audio/mp4',
        'audio/mpeg',
        'audio/wav',
      ],
      _ => [
        'application/pdf',
        'application/octet-stream',
        'text/plain',
        'application/zip',
      ],
    };
    if (!allowed.contains(mime)) return null;
    try {
      final bytes = base64Decode(match.group(2)!);
      if (bytes.isEmpty || bytes.length > 2 * 1024 * 1024) return null;
      p.addAll({
        'data': data,
        'name': name.replaceAll(RegExp(r'[\\/\x00-\x1f]'), '_'),
        'bytes': bytes.length,
      });
    } catch (_) {
      return null;
    }
  } else if (kind == 'location') {
    final label = text('label', 120), address = text('address', 300);
    if (label == null || label.trim().isEmpty || address == null) return null;
    p.addAll({'label': label, 'address': address});
  } else if (kind == 'contact') {
    final roleId = text('roleId', 100), name = text('name', 80);
    if (roleId == null || roleId.isEmpty || name == null || name.isEmpty)
      return null;
    p.addAll({'roleId': roleId, 'name': name});
  } else if (kind == 'call') {
    final duration = payload['duration'];
    if (duration is! int || duration < 0 || duration > 86400) return null;
    p.addAll({'duration': duration, 'video': payload['video'] == true});
  } else {
    return null;
  }
  return {
    'id': id,
    'kind': kind,
    'payload': p,
    'created': created.toLocal().toIso8601String(),
    'user': raw['user'] != false,
  };
}

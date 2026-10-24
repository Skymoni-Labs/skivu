import 'dart:convert';

String libraryId(String prefix) =>
    '$prefix-${DateTime.now().microsecondsSinceEpoch}';

bool validChatImage(dynamic value) =>
    value is String &&
    value.length <= 850000 &&
    RegExp(
      r'^data:image/(png|jpeg|webp);base64,[A-Za-z0-9+/=]+$',
    ).hasMatch(value);

class WorldEntry {
  WorldEntry({
    required this.id,
    required this.name,
    required this.category,
    required this.content,
    this.scene = false,
  });
  final String id;
  String name, category, content;
  bool scene;
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'category': category,
    'content': content,
    'scene': scene,
  };
  factory WorldEntry.fromJson(Map raw) => WorldEntry(
    id: libraryText(raw['id'], 100),
    name: libraryText(raw['name'], 80),
    category: libraryText(raw['category'], 40),
    content: libraryText(raw['content'], 12000),
    scene: raw['scene'] == true,
  );
}

class WorldSetting {
  WorldSetting({
    required this.id,
    required this.name,
    this.category = '未分类',
    this.summary = '',
    List<WorldEntry>? entries,
  }) : entries = entries ?? [];
  final String id;
  String name, category, summary;
  final List<WorldEntry> entries;
  List<WorldEntry> get scenes => entries.where((e) => e.scene).toList();
  String prompt(String? sceneId) => [
    '共用世界观：$name',
    if (summary.trim().isNotEmpty) summary,
    for (final entry in entries.where((e) => !e.scene))
      '[${entry.category}] ${entry.name}\n${entry.content}',
    for (final entry in scenes.where((e) => e.id == sceneId))
      '当前场景：${entry.name}\n${entry.content}',
  ].join('\n\n');
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'category': category,
    'summary': summary,
    'entries': entries.map((e) => e.toJson()).toList(),
  };
  factory WorldSetting.fromJson(Map raw) => WorldSetting(
    id: libraryText(raw['id'], 100),
    name: libraryText(raw['name'], 80),
    category: libraryText(raw['category'] ?? '未分类', 40),
    summary: libraryText(raw['summary'] ?? '', 20000),
    entries: [
      for (final entry in (raw['entries'] as List? ?? []).take(100))
        WorldEntry.fromJson(entry as Map),
    ],
  );
}

String libraryText(dynamic value, int max) {
  if (value is! String || value.length > max)
    throw const FormatException('资料格式不正确或内容过长');
  return value;
}

class StickerGroup {
  StickerGroup(this.id, this.name);
  final String id;
  String name;
  Map<String, dynamic> toJson() => {'id': id, 'name': name};
  factory StickerGroup.fromJson(Map raw) =>
      StickerGroup(libraryText(raw['id'], 100), libraryText(raw['name'], 40));
}

class StickerAsset {
  StickerAsset({
    required this.id,
    required this.groupId,
    required this.name,
    required this.data,
    this.active = true,
  });
  final String id, data;
  String groupId, name;
  bool active;
  Map<String, dynamic> toJson() => {
    'id': id,
    'groupId': groupId,
    'name': name,
    'data': data,
    'active': active,
  };
  factory StickerAsset.fromJson(Map raw) {
    final data = libraryText(raw['data'], 710000);
    if (!RegExp(
          r'^data:image/(png|jpeg|webp|gif);base64,[A-Za-z0-9+/=]+$',
        ).hasMatch(data) ||
        base64Decode(data.split(',').last).length > 512 * 1024) {
      throw const FormatException('表情图片无效或超过512KB');
    }
    return StickerAsset(
      id: libraryText(raw['id'], 100),
      groupId: libraryText(raw['groupId'], 100),
      name: libraryText(raw['name'], 80),
      data: data,
      active: raw['active'] != false,
    );
  }
}

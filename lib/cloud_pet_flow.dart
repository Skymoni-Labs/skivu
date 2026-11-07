import 'dart:ui';

/// Bundled bidirectional displacement data, not replacement character artwork.
class CloudPetFlow {
  CloudPetFlow.fromJson(Map<String, dynamic> value, int frameCount) {
    atlas = value['atlas'] as String;
    if (!atlas.startsWith('assets/branding/cloud_pet/') ||
        atlas.contains('..')) {
      throw const FormatException('Invalid cloud motion field path');
    }
    final dimensions = (value['size'] as List).cast<num>();
    size = Size(dimensions[0].toDouble(), dimensions[1].toDouble());
    cell = value['cell'] as int;
    columns = value['columns'] as int;
    range = (value['range'] as num).toDouble();
    final values = value['pairs'] as List;
    if (cell < 16 ||
        cell > 256 ||
        columns < 1 ||
        columns > 32 ||
        range <= 0 ||
        range > 64 ||
        values.isEmpty ||
        size.width != columns * cell * 2 ||
        size.height != ((values.length + columns - 1) ~/ columns) * cell ||
        size.longestSide > 4096) {
      throw const FormatException('Invalid cloud motion field dimensions');
    }
    for (var i = 0; i < values.length; i++) {
      final pair = (values[i] as List).cast<int>();
      if (pair.length != 2 ||
          pair.any((v) => v < 0 || v >= frameCount) ||
          pair[0] == pair[1]) {
        throw const FormatException('Invalid cloud motion edge');
      }
      final key = '${pair[0]}:${pair[1]}';
      if (edges.containsKey(key))
        throw const FormatException('Duplicate cloud motion edge');
      edges[key] = Offset(
        (i % columns * cell * 2).toDouble(),
        (i ~/ columns * cell).toDouble(),
      );
    }
  }
  late final String atlas;
  late final Size size;
  late final int cell, columns;
  late final double range;
  final edges = <String, Offset>{};
  Offset? origin(int first, int second) => edges['$first:$second'];
}

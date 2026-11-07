import 'cloud_companion_motion.dart';
import 'cloud_pet_pack.dart';

/// All workflow states have coherent full drawings, including the lightweight
/// loading fallback. Actual decoded textures are retained by the portrait.
class CloudPetCatalog {
  CloudPetCatalog.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1) {
      throw const FormatException('Unsupported cloud workflow catalog');
    }
    Map<CloudActivity, CloudPetPack> read(String key) {
      final raw = json[key] as Map;
      if (raw.length != CloudActivity.values.length ||
          CloudActivity.values.any(
            (activity) => !raw.containsKey(activity.name),
          )) {
        throw FormatException('Incomplete cloud workflow $key');
      }
      return Map.unmodifiable({
        for (final activity in CloudActivity.values)
          activity: (() {
            final pack = CloudPetPack.fromJson(
              Map<String, dynamic>.from(raw[activity.name] as Map),
            );
            if (!pack.wholeFrames || pack.activityName != activity.name) {
              throw FormatException(
                'Mismatched whole frame for ${activity.name}',
              );
            }
            return pack;
          })(),
      });
    }

    packs = read('packs');
    fallbacks = read('fallbacks');
    if (fallbacks.values.map((pack) => pack.atlas).toSet().length != 1) {
      throw const FormatException('Cloud loading frames must share one atlas');
    }
  }
  late final Map<CloudActivity, CloudPetPack> packs, fallbacks;
}

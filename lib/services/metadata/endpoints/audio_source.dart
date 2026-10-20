import 'package:spotube/services/metadata/retry.dart';
import 'package:hetu_script/hetu_script.dart';
import 'package:hetu_script/values.dart';
import 'package:spotube/models/metadata/metadata.dart';

class MetadataPluginAudioSourceEndpoint {
  final Hetu hetu;
  MetadataPluginAudioSourceEndpoint(this.hetu);

  HTInstance get hetuMetadataAudioSource =>
      (hetu.fetch("metadataPlugin") as HTInstance).memberGet("audioSource")
          as HTInstance;

  List<SpotubeAudioSourceContainerPreset> get supportedPresets {
    final raw = hetuMetadataAudioSource.memberGet("supportedPresets") as List;

    return raw
        .map((e) => SpotubeAudioSourceContainerPreset.fromJson(e))
        .toList();
  }

  /// [timeout] caps the plugin's own work (queue time excluded).
  Future<List<SpotubeAudioSourceMatchObject>> matches(
    SpotubeFullTrackObject track, {
    Duration? timeout,
  }) async {
    final raw = await hetuMetadataAudioSource.invokeWithRetry(
      "matches",
      positionalArgs: [track.toJson()],
      timeout: timeout,
    ) as List;

    return raw.map((e) => SpotubeAudioSourceMatchObject.fromJson(e)).toList();
  }

  /// [timeout] caps the plugin's own work (queue time excluded).
  Future<List<SpotubeAudioSourceStreamObject>> streams(
    SpotubeAudioSourceMatchObject match, {
    Duration? timeout,
  }) async {
    final raw = await hetuMetadataAudioSource.invokeWithRetry(
      "streams",
      positionalArgs: [match.toJson()],
      timeout: timeout,
    ) as List;

    return raw.map((e) => SpotubeAudioSourceStreamObject.fromJson(e)).toList();
  }
}

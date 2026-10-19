import 'package:spotube/services/metadata/retry.dart';
import 'package:hetu_script/hetu_script.dart';
import 'package:hetu_script/values.dart';
import 'package:spotube/models/metadata/metadata.dart';

class MetadataPluginTrackEndpoint {
  final Hetu hetu;
  MetadataPluginTrackEndpoint(this.hetu);

  HTInstance get hetuMetadataTrack =>
      (hetu.fetch("metadataPlugin") as HTInstance).memberGet("track")
          as HTInstance;

  Future<SpotubeFullTrackObject> getTrack(String id) async {
    final raw =
        await hetuMetadataTrack.invokeWithRetry("getTrack", positionalArgs: [id]) as Map;

    return SpotubeFullTrackObject.fromJson(
      raw.cast<String, dynamic>(),
    );
  }

  Future<void> save(List<String> ids) async {
    await hetuMetadataTrack.invokeWithRetry("save", positionalArgs: [ids]);
  }

  Future<void> unsave(List<String> ids) async {
    await hetuMetadataTrack.invokeWithRetry("unsave", positionalArgs: [ids]);
  }

  Future<List<SpotubeFullTrackObject>> radio(String id) async {
    final result = await hetuMetadataTrack.invokeWithRetry(
      "radio",
      positionalArgs: [id],
    );

    return (result as List)
        .map(
          (e) => SpotubeFullTrackObject.fromJson(
            (e as Map).cast<String, dynamic>(),
          ),
        )
        .toList();
  }
}

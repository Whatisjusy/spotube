import 'package:spotube/services/metadata/retry.dart';
import 'package:hetu_script/hetu_script.dart';
import 'package:hetu_script/values.dart';
import 'package:spotube/models/metadata/metadata.dart';

class MetadataPluginPlaylistEndpoint {
  final Hetu hetu;
  MetadataPluginPlaylistEndpoint(this.hetu);

  HTInstance get hetuMetadataPlaylist =>
      (hetu.fetch("metadataPlugin") as HTInstance).memberGet("playlist")
          as HTInstance;

  Future<SpotubeFullPlaylistObject> getPlaylist(String id) async {
    final raw = await hetuMetadataPlaylist
        .invokeWithRetry("getPlaylist", positionalArgs: [id]) as Map;

    return SpotubeFullPlaylistObject.fromJson(
      raw.cast<String, dynamic>(),
    );
  }

  Future<SpotubePaginationResponseObject<SpotubeFullTrackObject>> tracks(
    String id, {
    int? offset,
    int? limit,
  }) async {
    final raw = await hetuMetadataPlaylist.invokeWithRetry(
      "tracks",
      positionalArgs: [id],
      namedArgs: {
        "offset": offset,
        "limit": limit,
      }..removeWhere((key, value) => value == null),
    ) as Map;

    return SpotubePaginationResponseObject<SpotubeFullTrackObject>.fromJson(
      raw.cast<String, dynamic>(),
      (Map json) =>
          SpotubeFullTrackObject.fromJson(json.cast<String, dynamic>()),
    );
  }

  Future<SpotubeFullPlaylistObject?> create(
    String userId, {
    required String name,
    String? description,
    bool? public,
    bool? collaborative,
  }) async {
    final raw = await hetuMetadataPlaylist.invokeWithRetry(
      "create",
      positionalArgs: [userId],
      namedArgs: {
        "name": name,
        "description": description,
        "public": public,
        "collaborative": collaborative,
      }..removeWhere((key, value) => value == null),
    ) as Map?;

    if (raw == null) return null;

    return SpotubeFullPlaylistObject.fromJson(
      raw.cast<String, dynamic>(),
    );
  }

  Future<void> update(
    String playlistId, {
    String? name,
    String? description,
    bool? public,
    bool? collaborative,
  }) async {
    await hetuMetadataPlaylist.invokeWithRetry(
      "update",
      positionalArgs: [playlistId],
      namedArgs: {
        "name": name,
        "description": description,
        "public": public,
        "collaborative": collaborative,
      }..removeWhere((key, value) => value == null),
    );
  }

  Future<void> addTracks(
    String playlistId, {
    required List<String> trackIds,
    int? position,
  }) async {
    await hetuMetadataPlaylist.invokeWithRetry(
      "addTracks",
      positionalArgs: [playlistId],
      namedArgs: {
        "trackIds": trackIds,
        "position": position,
      }..removeWhere((key, value) => value == null),
    );
  }

  Future<void> removeTracks(
    String playlistId, {
    required List<String> trackIds,
  }) async {
    await hetuMetadataPlaylist.invokeWithRetry(
      "removeTracks",
      positionalArgs: [playlistId],
      namedArgs: {
        "trackIds": trackIds,
      }..removeWhere((key, value) => value == null),
    );
  }

  Future<void> save(String playlistId) async {
    await hetuMetadataPlaylist.invokeWithRetry(
      "save",
      positionalArgs: [playlistId],
    );
  }

  Future<void> unsave(String playlistId) async {
    await hetuMetadataPlaylist.invokeWithRetry(
      "unsave",
      positionalArgs: [playlistId],
    );
  }

  Future<void> deletePlaylist(String playlistId) async {
    return await hetuMetadataPlaylist.invokeWithRetry(
      "deletePlaylist",
      positionalArgs: [playlistId],
    );
  }
}

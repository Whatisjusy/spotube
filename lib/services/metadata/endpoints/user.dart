import 'package:spotube/services/metadata/retry.dart';
import 'package:hetu_script/hetu_script.dart';
import 'package:hetu_script/values.dart';
import 'package:spotube/models/metadata/metadata.dart';

class MetadataPluginUserEndpoint {
  final Hetu hetu;
  MetadataPluginUserEndpoint(this.hetu);

  HTInstance get hetuMetadataUser =>
      (hetu.fetch("metadataPlugin") as HTInstance).memberGet("user")
          as HTInstance;

  Future<SpotubeUserObject> me() async {
    final raw = await hetuMetadataUser.invokeWithRetry("me") as Map;

    return SpotubeUserObject.fromJson(
      raw.cast<String, dynamic>(),
    );
  }

  Future<SpotubePaginationResponseObject<SpotubeFullTrackObject>> savedTracks({
    int? offset,
    int? limit,
  }) async {
    final raw = await hetuMetadataUser.invokeWithRetry(
      "savedTracks",
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

  Future<SpotubePaginationResponseObject<SpotubeSimplePlaylistObject>>
      savedPlaylists({
    int? offset,
    int? limit,
  }) async {
    final raw = await hetuMetadataUser.invokeWithRetry(
      "savedPlaylists",
      namedArgs: {
        "offset": offset,
        "limit": limit,
      }..removeWhere((key, value) => value == null),
    ) as Map;

    return SpotubePaginationResponseObject<
        SpotubeSimplePlaylistObject>.fromJson(
      raw.cast<String, dynamic>(),
      (Map json) =>
          SpotubeSimplePlaylistObject.fromJson(json.cast<String, dynamic>()),
    );
  }

  Future<SpotubePaginationResponseObject<SpotubeSimpleAlbumObject>>
      savedAlbums({
    int? offset,
    int? limit,
  }) async {
    final raw = await hetuMetadataUser.invokeWithRetry(
      "savedAlbums",
      namedArgs: {
        "offset": offset,
        "limit": limit,
      }..removeWhere((key, value) => value == null),
    ) as Map;

    return SpotubePaginationResponseObject<SpotubeSimpleAlbumObject>.fromJson(
      raw.cast<String, dynamic>(),
      (Map json) =>
          SpotubeSimpleAlbumObject.fromJson(json.cast<String, dynamic>()),
    );
  }

  Future<SpotubePaginationResponseObject<SpotubeFullArtistObject>>
      savedArtists({
    int? offset,
    int? limit,
  }) async {
    final raw = await hetuMetadataUser.invokeWithRetry(
      "savedArtists",
      namedArgs: {
        "offset": offset,
        "limit": limit,
      }..removeWhere((key, value) => value == null),
    ) as Map;

    return SpotubePaginationResponseObject<SpotubeFullArtistObject>.fromJson(
      raw.cast<String, dynamic>(),
      (Map json) =>
          SpotubeFullArtistObject.fromJson(json.cast<String, dynamic>()),
    );
  }

  Future<bool> isSavedPlaylist(String playlistId) async {
    return await hetuMetadataUser.invokeWithRetry(
      "isSavedPlaylist",
      positionalArgs: [playlistId],
    ) as bool;
  }

  Future<List<bool>> isSavedTracks(List<String> ids) async {
    final values = await hetuMetadataUser.invokeWithRetry(
      "isSavedTracks",
      positionalArgs: [ids],
    );
    return (values as List).cast<bool>();
  }

  Future<List<bool>> isSavedAlbums(List<String> ids) async {
    final values = await hetuMetadataUser.invokeWithRetry(
      "isSavedAlbums",
      positionalArgs: [ids],
    ) as List;
    return values.cast<bool>();
  }

  Future<List<bool>> isSavedArtists(List<String> ids) async {
    final values = await hetuMetadataUser.invokeWithRetry(
      "isSavedArtists",
      positionalArgs: [ids],
    ) as List;

    return values.cast<bool>();
  }
}

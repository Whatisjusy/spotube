import 'package:flutter/foundation.dart';
import 'package:spotube/services/logger/logger.dart';
import 'package:spotube/services/metadata/retry.dart';
import 'package:spotube/services/metadata/spotify_gql.dart';
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
    final viaGql = await _libraryFromGql(
      "savedAlbums",
      filter: "Albums",
      offset: offset,
      limit: limit,
      parse: libraryAlbumFromGql,
    );
    if (viaGql != null) return viaGql;

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
    final viaGql = await _libraryFromGql(
      "savedArtists",
      filter: "Artists",
      offset: offset,
      limit: limit,
      parse: libraryArtistFromGql,
    );
    if (viaGql != null) return viaGql;

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

  // Hash of the plugin's own libraryV3 query.
  static const _libraryV3Hash =
      "2de10199b2441d6e4ae875f27d2db361020c399fb10b03951120223fbed10b08";

  /// One page of Library albums or artists, read straight from the plugin's
  /// libraryV3 query. The plugin makes the same query but then asks the old
  /// API (`/v1/albums?ids=`, `/v1/artists?ids=`) for details that the reply
  /// already holds, and that second step is refused (see [SpotifyGql]).
  /// Null when the plugin is not the Spotify one or the query fails, so the
  /// caller falls back to the plugin's own call.
  Future<SpotubePaginationResponseObject<T>?> _libraryFromGql<T>(
    String funcName, {
    required String filter,
    required int? offset,
    required int? limit,
    required T? Function(Map data) parse,
  }) async {
    final gql = SpotifyGql.of(hetuMetadataUser);
    if (gql == null) return null;
    try {
      final page = libraryPageFromGql(
        await gql.query(
          funcName,
          operation: "libraryV3",
          hash: _libraryV3Hash,
          variables: {
            "filters": [filter],
            "order": null,
            "textFilter": "",
            "features": [
              "LIKED_SONGS",
              "YOUR_EPISODES_V2",
              "PRERELEASES",
              "EVENTS",
            ],
            "limit": limit ?? 20,
            "offset": offset ?? 0,
            "flatten": false,
            "expandedFolders": [],
            "folderUri": null,
            "includeFoldersWhenFlattening": true,
          },
        ),
        parse,
      );
      AppLogger.log.i(
        "Library $filter: ${page.items.length} of ${page.total} "
        "(from ${offset ?? 0})",
      );
      return page;
    } catch (e) {
      AppLogger.log.w(
        "Library $filter: Spotify's library query failed, "
        "using the plugin's own call: $e",
      );
      return null;
    }
  }
}

/// Reads one libraryV3 page. [parse] turns an item's `data` into a result,
/// or null for items of another kind (they are skipped).
@visibleForTesting
SpotubePaginationResponseObject<T> libraryPageFromGql<T>(
  dynamic reply,
  T? Function(Map data) parse,
) {
  final library = (reply is Map ? reply["data"] : null)?["me"]?["libraryV3"];
  final rawItems = library is Map ? library["items"] : null;
  if (rawItems is! List) {
    throw FormatException(
      "no library items in the reply: ${reply is Map ? reply["errors"] : reply}",
    );
  }

  final paging = library["pagingInfo"];
  final offset =
      (paging is Map ? paging["offset"] as num? : null)?.toInt() ?? 0;
  final limit = (paging is Map ? paging["limit"] as num? : null)?.toInt() ??
      rawItems.length;
  final total = (library["totalCount"] as num?)?.toInt() ?? rawItems.length;
  final hasMore = rawItems.isNotEmpty && offset + rawItems.length < total;

  return SpotubePaginationResponseObject(
    limit: limit,
    nextOffset: hasMore ? offset + rawItems.length : null,
    total: total,
    hasMore: hasMore,
    items: [
      for (final item in rawItems.whereType<Map>())
        if (item["item"]?["data"] case final Map data)
          if (parse(data) case final T parsed) parsed,
    ],
  );
}

/// A libraryV3 Artist. Throws when it has no name, which means the query's
/// fields changed and the plugin's own call should be used instead.
@visibleForTesting
SpotubeFullArtistObject? libraryArtistFromGql(Map data) {
  if (data["__typename"] != "Artist") return null;
  final id = _idFromUri(data["uri"], "artist");
  final name = data["profile"]?["name"];
  if (id == null || name is! String) {
    throw FormatException("library artist without id or name: $data");
  }
  return SpotubeFullArtistObject(
    id: id,
    name: name,
    externalUri: "https://open.spotify.com/artist/$id",
    images: _imagesFromGql(data["visuals"]?["avatarImage"]?["sources"]),
  );
}

/// A libraryV3 Album. Throws when it has no name (see [libraryArtistFromGql]).
@visibleForTesting
SpotubeSimpleAlbumObject? libraryAlbumFromGql(Map data) {
  if (data["__typename"] != "Album") return null;
  final id = _idFromUri(data["uri"], "album");
  final name = data["name"];
  if (id == null || name is! String) {
    throw FormatException("library album without id or name: $data");
  }
  final date = data["date"];
  final iso = date is Map ? date["isoString"] : null;
  return SpotubeSimpleAlbumObject(
    id: id,
    name: name,
    externalUri: "https://open.spotify.com/album/$id",
    artists: [
      for (final artist
          in (data["artists"]?["items"] as List?)?.whereType<Map>() ??
              const <Map>[])
        if (_idFromUri(artist["uri"], "artist") case final String artistId)
          SpotubeSimpleArtistObject(
            id: artistId,
            name: artist["profile"]?["name"] as String? ?? "",
            externalUri: "https://open.spotify.com/artist/$artistId",
          ),
    ],
    images: _imagesFromGql(data["coverArt"]?["sources"]),
    // Same mapping as the plugin: EPs count as compilations.
    albumType: switch ((data["type"] as String?)?.toUpperCase()) {
      "SINGLE" => SpotubeAlbumType.single,
      "COMPILATION" || "EP" => SpotubeAlbumType.compilation,
      _ => SpotubeAlbumType.album,
    },
    releaseDate: iso is String
        ? switch (date["precision"]) {
            "YEAR" when iso.length >= 4 => iso.substring(0, 4),
            "MONTH" when iso.length >= 7 => iso.substring(0, 7),
            _ when iso.length >= 10 => iso.substring(0, 10),
            _ => iso,
          }
        : null,
  );
}

String? _idFromUri(dynamic uri, String kind) {
  final prefix = "spotify:$kind:";
  return uri is String && uri.startsWith(prefix) && uri.length > prefix.length
      ? uri.substring(prefix.length)
      : null;
}

List<SpotubeImageObject> _imagesFromGql(dynamic sources) => [
      for (final source
          in (sources as List?)?.whereType<Map>() ?? const <Map>[])
        if (source["url"] case final String url)
          SpotubeImageObject(
            url: url,
            width: (source["width"] as num?)?.toInt(),
            height: (source["height"] as num?)?.toInt(),
          ),
    ];

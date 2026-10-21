import 'package:flutter/foundation.dart';
import 'package:spotube/services/logger/logger.dart';
import 'package:spotube/services/metadata/retry.dart';
import 'package:spotube/services/metadata/spotify_gql.dart';
import 'package:hetu_script/hetu_script.dart';
import 'package:hetu_script/values.dart';
import 'package:spotube/models/metadata/metadata.dart';

class MetadataPluginArtistEndpoint {
  final Hetu hetu;
  MetadataPluginArtistEndpoint(this.hetu);

  HTInstance get hetuMetadataArtist =>
      (hetu.fetch("metadataPlugin") as HTInstance).memberGet("artist")
          as HTInstance;

  Future<SpotubeFullArtistObject> getArtist(String id) async {
    final raw = await hetuMetadataArtist
        .invokeWithRetry("getArtist", positionalArgs: [id]) as Map;

    return SpotubeFullArtistObject.fromJson(
      raw.cast<String, dynamic>(),
    );
  }

  Future<SpotubePaginationResponseObject<SpotubeFullTrackObject>> topTracks(
    String id, {
    int? offset,
    int? limit,
  }) async {
    final raw = await hetuMetadataArtist.invokeWithRetry(
      "topTracks",
      positionalArgs: [id],
      namedArgs: {
        "offset": offset,
        "limit": limit,
      }..removeWhere((key, value) => value == null),
    ) as Map;

    return SpotubePaginationResponseObject<SpotubeFullTrackObject>.fromJson(
      raw.cast<String, dynamic>(),
      (Map json) => SpotubeFullTrackObject.fromJson(
        json.cast<String, dynamic>(),
      ),
    );
  }

  Future<SpotubePaginationResponseObject<SpotubeSimpleAlbumObject>> albums(
    String id, {
    int? offset,
    int? limit,
  }) async {
    final raw = await hetuMetadataArtist.invokeWithRetry(
      "albums",
      positionalArgs: [id],
      namedArgs: {
        "offset": offset,
        "limit": limit,
      }..removeWhere((key, value) => value == null),
    ) as Map;

    return SpotubePaginationResponseObject<SpotubeSimpleAlbumObject>.fromJson(
      raw.cast<String, dynamic>(),
      (Map json) => SpotubeSimpleAlbumObject.fromJson(
        json.cast<String, dynamic>(),
      ),
    );
  }

  Future<void> save(List<String> ids) async {
    await hetuMetadataArtist.invokeWithRetry(
      "save",
      positionalArgs: [ids],
    );
  }

  Future<void> unsave(List<String> ids) async {
    await hetuMetadataArtist.invokeWithRetry(
      "unsave",
      positionalArgs: [ids],
    );
  }

  Future<SpotubePaginationResponseObject<SpotubeFullArtistObject>> related(
    String id, {
    int? offset,
    int? limit,
  }) async {
    final gql = SpotifyGql.of(hetuMetadataArtist);
    if (gql != null) {
      try {
        final artists = relatedArtistsFromGql(
          await gql.query(
            "related",
            operation: "queryArtistRelated",
            hash:
                "3d031d6cb22a2aa7c8d203d49b49df731f58b1e2799cc38d9876d58771aa66f3",
            variables: {"uri": "spotify:artist:$id"},
          ),
        );
        AppLogger.log.i("Fans also like for $id: ${artists.length} artists");
        return SpotubePaginationResponseObject(
          limit: limit ?? 20,
          nextOffset: null,
          total: artists.length,
          hasMore: false,
          items: artists,
        );
      } catch (e) {
        AppLogger.log.w(
          "Fans also like: Spotify's artist query failed, "
          "using the plugin's own call: $e",
        );
      }
    }

    final raw = await hetuMetadataArtist.invokeWithRetry(
      "related",
      positionalArgs: [id],
      namedArgs: {
        "offset": offset,
        "limit": limit ?? 20,
      }..removeWhere((key, value) => value == null),
    ) as Map;

    return SpotubePaginationResponseObject<SpotubeFullArtistObject>.fromJson(
      raw.cast<String, dynamic>(),
      (Map json) => SpotubeFullArtistObject.fromJson(
        json.cast<String, dynamic>(),
      ),
    );
  }
}

/// Reads "Fans also like" out of a `queryArtistRelated` reply.
@visibleForTesting
List<SpotubeFullArtistObject> relatedArtistsFromGql(dynamic data) {
  final items = (data is Map ? data["data"] : null)?["artistUnion"]
      ?["relatedContent"]?["relatedArtists"]?["items"];
  if (items is! List) {
    throw FormatException(
      "no related artists in the reply: ${data is Map ? data["errors"] : data}",
    );
  }

  return [
    for (final item in items.whereType<Map>())
      if (_artistId(item) case final String id)
        SpotubeFullArtistObject(
          id: id,
          name: item["profile"]?["name"] as String? ?? "",
          externalUri: "https://open.spotify.com/artist/$id",
          images: [
            for (final source
                in (item["visuals"]?["avatarImage"]?["sources"] as List?)
                        ?.whereType<Map>() ??
                    const <Map>[])
              if (source["url"] case final String url)
                SpotubeImageObject(
                  url: url,
                  width: (source["width"] as num?)?.toInt(),
                  height: (source["height"] as num?)?.toInt(),
                ),
          ],
        ),
  ];
}

String? _artistId(Map item) {
  if (item["id"] case final String id when id.isNotEmpty) return id;
  final uri = item["uri"];
  return uri is String && uri.startsWith("spotify:artist:")
      ? uri.substring("spotify:artist:".length)
      : null;
}

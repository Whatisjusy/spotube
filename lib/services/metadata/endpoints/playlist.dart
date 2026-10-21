import 'package:flutter/foundation.dart';
import 'package:spotube/services/logger/logger.dart';
import 'package:spotube/services/metadata/retry.dart';
import 'package:spotube/services/metadata/spotify_gql.dart';
import 'package:hetu_script/hetu_script.dart';
import 'package:hetu_script/values.dart';
import 'package:spotube/models/metadata/metadata.dart';

// Local change: playlist edits and follow/unfollow go to Spotify's query
// server and playlist server first. The Spotify plugin 0.2.2 sends them to
// the old API, which Spotify refuses (see SpotifyGql). Requests are the ones
// the plugin's newer Kotlin version makes (PlaylistClient.kt), checked
// against Spotify's own web player. Each falls back to the plugin's own call
// on any error.

// addToPlaylist and removeFromPlaylist live in one query document, so they
// share a hash (Spotify's web player does the same).
const _playlistItemsHash =
    "47b2a1234b17748d332dd0431534f22450e9ecbb3d5ddcdacbd83368636a0990";
const _addToRootlistHash =
    "bd9c5cae1ee80ebca05d7ed12fd394216f49a20ce72d9dc762868df0f14522ea";
const _removeFromRootlistHash =
    "3422f1866532820a1d8d0560f88542dbdbd35d0377ee5ecd49593590f5f1e86b";
// The plugin's own fetchPlaylist query.
const _fetchPlaylistHash =
    "bb67e0af06e8d6f52b531f97468ee4acd44cd0f82b988e15c2ea47b1148efc77";

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
    // Collaborative playlists are not made this way; the plugin's call is.
    final gql =
        collaborative == true ? null : SpotifyGql.of(hetuMetadataPlaylist);
    if (gql != null) {
      String? id;
      try {
        id = createdPlaylistIdFromReply(
          await gql.post(
            "create",
            "/playlist/v2/playlist?format=json",
            body: createPlaylistBody(name: name, description: description),
          ),
        );
      } catch (e) {
        AppLogger.log.w(
          "Create playlist: Spotify's playlist server failed, "
          "using the plugin's own call: $e",
        );
      }
      // Made, so no going back to the plugin's create (that would make a
      // second one). The next steps have their own fallbacks.
      if (id != null) {
        AppLogger.log.i('Created playlist "$name" ($id)');
        await save(id);
        await _setPublic(gql, userId, id, public ?? false, name: name);
        try {
          return await getPlaylist(id);
        } catch (e) {
          // The plugin's getPlaylist takes the first cover picture, and a new
          // empty playlist has none (RangeError, Mac 2026-10-21).
          AppLogger.log.w("Created playlist $id, but cannot read it yet: $e");
          return SpotubeFullPlaylistObject(
            id: id,
            name: name,
            description: description ?? "",
            externalUri: "https://open.spotify.com/playlist/$id",
            owner: SpotubeUserObject(
              id: userId,
              name: userId,
              externalUri: "https://open.spotify.com/user/$userId",
            ),
            public: public ?? false,
          );
        }
      }
    }

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

  /// [userId] is needed to change [public] on Spotify's playlist server.
  Future<void> update(
    String playlistId, {
    String? name,
    String? description,
    bool? public,
    bool? collaborative,
    String? userId,
  }) async {
    final gql = collaborative != null || (public != null && userId == null)
        ? null
        : SpotifyGql.of(hetuMetadataPlaylist);
    if (gql != null) {
      try {
        if (name != null || description != null) {
          revisionFromReply(
            await gql.post(
              "update",
              "/playlist/v2/playlist/$playlistId/changes?format=json",
              body: updatePlaylistBody(name: name, description: description),
            ),
          );
        }
        if (public != null) {
          revisionFromReply(
            await gql.post(
              "update",
              "/playlist/v2/user/${Uri.encodeComponent(userId!)}"
                  "/rootlist/changes?format=json",
              body: publicChangeBody(playlistId, public),
            ),
          );
        }
        AppLogger.log.i("Updated playlist $playlistId");
        return;
      } catch (e) {
        AppLogger.log.w(
          "Update playlist: Spotify's playlist server failed, "
          "using the plugin's own call: $e",
        );
      }
    }

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
    // Spotify's query adds to the end; a set position uses the plugin's call.
    final gql = position != null ? null : SpotifyGql.of(hetuMetadataPlaylist);
    if (gql != null) {
      try {
        expectMutationReply(
          await gql.query(
            "addTracks",
            operation: "addToPlaylist",
            hash: _playlistItemsHash,
            variables: addToPlaylistVariables(playlistId, trackIds),
          ),
          "addItemsToPlaylist",
        );
        AppLogger.log.i(
          "Added ${trackIds.length} songs to playlist $playlistId",
        );
        return;
      } catch (e) {
        AppLogger.log.w(
          "Add to playlist: Spotify's query failed, "
          "using the plugin's own call: $e",
        );
      }
    }

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
    final gql = SpotifyGql.of(hetuMetadataPlaylist);
    if (gql != null) {
      try {
        // Spotify removes rows, not songs: every row holding one of the
        // songs is looked up first, like the old API's remove did.
        final uids = await _rowsOf(gql, playlistId, trackIds.toSet());
        if (uids.isNotEmpty) {
          expectMutationReply(
            await gql.query(
              "removeTracks",
              operation: "removeFromPlaylist",
              hash: _playlistItemsHash,
              variables: {
                "playlistUri": "spotify:playlist:$playlistId",
                "uids": uids,
              },
            ),
            "removeItemsFromPlaylist",
          );
        }
        AppLogger.log.i(
          "Removed ${uids.length} rows from playlist $playlistId",
        );
        return;
      } catch (e) {
        AppLogger.log.w(
          "Remove from playlist: Spotify's query failed, "
          "using the plugin's own call: $e",
        );
      }
    }

    await hetuMetadataPlaylist.invokeWithRetry(
      "removeTracks",
      positionalArgs: [playlistId],
      namedArgs: {
        "trackIds": trackIds,
      }..removeWhere((key, value) => value == null),
    );
  }

  Future<void> save(String playlistId) async {
    if (await _changeLibrary("save", playlistId, add: true)) return;

    await hetuMetadataPlaylist.invokeWithRetry(
      "save",
      positionalArgs: [playlistId],
    );
  }

  Future<void> unsave(String playlistId) async {
    if (await _changeLibrary("unsave", playlistId, add: false)) return;

    await hetuMetadataPlaylist.invokeWithRetry(
      "unsave",
      positionalArgs: [playlistId],
    );
  }

  /// Spotify has no delete: the plugin removes the playlist from the
  /// Library, as Spotify's own apps do.
  Future<void> deletePlaylist(String playlistId) async {
    if (await _changeLibrary("deletePlaylist", playlistId, add: false)) return;

    return await hetuMetadataPlaylist.invokeWithRetry(
      "deletePlaylist",
      positionalArgs: [playlistId],
    );
  }

  /// Adds the playlist to the Library or removes it. False when the plugin
  /// is not the Spotify one or the query failed.
  Future<bool> _changeLibrary(
    String funcName,
    String playlistId, {
    required bool add,
  }) async {
    final gql = SpotifyGql.of(hetuMetadataPlaylist);
    if (gql == null) return false;
    final operation = add ? "addItemsToRootlist" : "removeItemsFromRootlist";
    try {
      expectMutationReply(
        await gql.query(
          funcName,
          operation: operation,
          hash: add ? _addToRootlistHash : _removeFromRootlistHash,
          variables: {
            "uris": ["spotify:playlist:$playlistId"],
          },
        ),
        operation,
      );
      AppLogger.log.i(
        "Playlist $playlistId ${add ? "added to" : "removed from"} Library",
      );
      return true;
    } catch (e) {
      AppLogger.log.w(
        "Playlist $funcName: Spotify's query failed, "
        "using the plugin's own call: $e",
      );
      return false;
    }
  }

  Future<void> _setPublic(
    SpotifyGql gql,
    String userId,
    String playlistId,
    bool public, {
    required String name,
  }) async {
    try {
      revisionFromReply(
        await gql.post(
          "update",
          "/playlist/v2/user/${Uri.encodeComponent(userId)}"
              "/rootlist/changes?format=json",
          body: publicChangeBody(playlistId, public),
        ),
      );
    } catch (e) {
      AppLogger.log.w(
        "Playlist public flag: Spotify's playlist server failed, "
        "using the plugin's own call: $e",
      );
      // The plugin's update needs the name.
      await hetuMetadataPlaylist.invokeWithRetry(
        "update",
        positionalArgs: [playlistId],
        namedArgs: {"name": name, "public": public},
      );
    }
  }

  /// The row ids (uids) of every row of the playlist holding one of
  /// [trackIds], read page by page with the plugin's own playlist query.
  Future<List<String>> _rowsOf(
    SpotifyGql gql,
    String playlistId,
    Set<String> trackIds,
  ) async {
    const limit = 100;
    final uids = <String>[];
    var offset = 0;
    while (true) {
      final page = playlistRowsFromGql(
        await gql.query(
          "tracks",
          operation: "fetchPlaylist",
          hash: _fetchPlaylistHash,
          variables: {
            "uri": "spotify:playlist:$playlistId",
            "offset": offset,
            "limit": limit,
            "enableWatchFeedEntrypoint": false,
          },
        ),
      );
      uids.addAll([
        for (final row in page.rows)
          if (trackIds.contains(row.trackId)) row.uid,
      ]);
      offset += page.rows.length;
      if (page.rows.isEmpty || offset >= page.total) return uids;
    }
  }
}

/// Body for creating a playlist on Spotify's playlist server.
@visibleForTesting
Map<String, dynamic> createPlaylistBody({
  required String name,
  String? description,
}) =>
    {
      "ops": [
        {
          "kind": "UPDATE_LIST_ATTRIBUTES",
          "updateListAttributes": {
            "newAttributes": {
              "values": {
                "name": name,
                if (description != null) "description": description,
              },
            },
          },
        },
      ],
    };

/// Body for changing a playlist's name and/or description.
@visibleForTesting
Map<String, dynamic> updatePlaylistBody({String? name, String? description}) =>
    {
      "deltas": [
        {
          "ops": [
            {
              "kind": "UPDATE_LIST_ATTRIBUTES",
              "updateListAttributes": {
                "newAttributes": {
                  "values": {
                    if (name != null) "name": name,
                    if (description != null) "description": description,
                  },
                },
              },
            },
          ],
          "info": {
            "source": {"client": "WEBPLAYER"},
          },
        },
      ],
    };

/// Body for showing a playlist on the profile or not (the user's Library
/// list, not the playlist, holds that flag).
@visibleForTesting
Map<String, dynamic> publicChangeBody(String playlistId, bool public) => {
      "deltas": [
        {
          "ops": [
            {
              "kind": "UPDATE_ITEM_ATTRIBUTES",
              "updateItemAttributes": {
                "newAttributes": {
                  "values": {"public": public},
                },
                "item": {"uri": "spotify:playlist:$playlistId"},
              },
            },
          ],
          "info": {
            "source": {"client": "WEBPLAYER"},
          },
        },
      ],
    };

@visibleForTesting
Map<String, dynamic> addToPlaylistVariables(
  String playlistId,
  List<String> trackIds,
) =>
    {
      "playlistItemUris": [for (final id in trackIds) "spotify:track:$id"],
      "playlistUri": "spotify:playlist:$playlistId",
      "newPosition": {"moveType": "BOTTOM_OF_PLAYLIST", "fromUid": null},
    };

/// The new playlist's id from the playlist server's create reply.
@visibleForTesting
String createdPlaylistIdFromReply(dynamic reply) {
  final uri = reply is Map ? reply["uri"] : null;
  if (uri is String && uri.startsWith("spotify:playlist:")) {
    final id = uri.substring("spotify:playlist:".length);
    if (id.isNotEmpty) return id;
  }
  throw FormatException("no playlist in the create reply: $reply");
}

/// Checks a playlist server change reply, which carries the new revision.
@visibleForTesting
String revisionFromReply(dynamic reply) {
  final revision = reply is Map ? reply["revision"] : null;
  if (revision is String && revision.isNotEmpty) return revision;
  throw FormatException("no revision in the change reply: $reply");
}

/// Checks a query-server change reply: Spotify answers 200 with `errors`
/// and no result when a change was refused.
@visibleForTesting
void expectMutationReply(dynamic reply, String field) {
  final result = (reply is Map ? reply["data"] : null)?[field];
  if (result is! Map || result["__typename"] is! String) {
    throw FormatException(
      "no $field in the reply: ${reply is Map ? reply["errors"] : reply}",
    );
  }
}

/// One fetchPlaylist page as (row id, song id) pairs. Rows that are not
/// songs (episodes, local files) have no song id.
@visibleForTesting
({List<({String uid, String? trackId})> rows, int total}) playlistRowsFromGql(
  dynamic reply,
) {
  final content =
      (reply is Map ? reply["data"] : null)?["playlistV2"]?["content"];
  final items = content is Map ? content["items"] : null;
  if (items is! List) {
    throw FormatException(
      "no playlist items in the reply: ${reply is Map ? reply["errors"] : reply}",
    );
  }
  final rows = <({String uid, String? trackId})>[];
  for (final item in items.whereType<Map>()) {
    final uid = item["uid"];
    if (uid is! String || uid.isEmpty) {
      throw FormatException("playlist row without uid: $item");
    }
    final uri = item["itemV2"]?["data"]?["uri"];
    rows.add((
      uid: uid,
      trackId: uri is String && uri.startsWith("spotify:track:")
          ? uri.substring("spotify:track:".length)
          : null,
    ));
  }
  return (
    rows: rows,
    total: (content["totalCount"] as num?)?.toInt() ?? rows.length,
  );
}

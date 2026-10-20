import 'package:flutter/foundation.dart';
import 'package:spotube/services/logger/logger.dart';
import 'package:spotube/services/metadata/retry.dart';
import 'package:hetu_script/hetu_script.dart';
import 'package:hetu_script/values.dart';
import 'package:spotube/models/metadata/metadata.dart';

/// The Spotify plugin (0.2.2) breaks on the last page of every search tab.
/// Its client passes on Spotify's `nextOffset` as `offset`, which is null
/// when there is no next page, and `Converters.paginated` adds to it
/// ("The method '+' was called on null", converter.ht). So any tab with 20
/// results or fewer failed (owner, 2026-10-20: "looking for an artist").
@visibleForTesting
bool isPluginLastPageCrash(Object error) {
  final text = "$error";
  return text.contains("converter.ht") && text.contains("was called on null");
}

/// When the plugin does answer, its next offset is Spotify's next offset
/// plus another page, so "load more" skipped a page, and its `hasMore`
/// said no for 21-39 results. Work both out from where this page started.
@visibleForTesting
SpotubePaginationResponseObject<T> fixSearchPaging<T>(
  SpotubePaginationResponseObject<T> page, {
  required int offset,
  required int limit,
}) {
  final next = offset + limit;
  final hasMore = page.items.isNotEmpty && next < page.total;
  return page.copyWith(
    limit: limit,
    hasMore: hasMore,
    nextOffset: hasMore ? next : null,
  );
}

/// One page of a search tab, with the plugin's paging corrected, and when
/// the plugin crashes on its last page: on the first page the same kind of
/// results from the "All" search (which does not page and does not crash),
/// on later pages the end of the list.
@visibleForTesting
Future<SpotubePaginationResponseObject<T>> searchPageWithFallback<T>({
  required String label,
  required int offset,
  required int limit,
  required Future<SpotubePaginationResponseObject<T>> Function() page,
  required Future<List<T>> Function() fromAll,
}) async {
  try {
    return fixSearchPaging(await page(), offset: offset, limit: limit);
  } catch (e) {
    if (!isPluginLastPageCrash(e)) rethrow;
    final items = offset == 0 ? await fromAll() : <T>[];
    AppLogger.log.i(
      "Search $label: the plugin failed on its last page; "
      "${offset == 0 ? "using ${items.length} from the All search" : "end of list"}",
    );
    return SpotubePaginationResponseObject<T>(
      items: items,
      total: offset + items.length,
      limit: limit,
      hasMore: false,
      nextOffset: null,
    );
  }
}

class MetadataPluginSearchEndpoint {
  final Hetu hetu;
  MetadataPluginSearchEndpoint(this.hetu);

  HTInstance get hetuMetadataSearch =>
      (hetu.fetch("metadataPlugin") as HTInstance).memberGet("search")
          as HTInstance;

  List<String> get chips {
    return (hetuMetadataSearch.memberGet("chips") as List).cast<String>();
  }

  Future<SpotubeSearchResponseObject> all(String query) async {
    if (query.isEmpty) {
      return SpotubeSearchResponseObject(
        albums: [],
        artists: [],
        playlists: [],
        tracks: [],
      );
    }

    final raw = await hetuMetadataSearch.invokeWithRetry(
      "all",
      positionalArgs: [query],
    ) as Map;

    return SpotubeSearchResponseObject.fromJson(raw.cast<String, dynamic>());
  }

  Future<SpotubePaginationResponseObject<T>> _page<T>(
    String funcName,
    String query, {
    required int? limit,
    required int? offset,
    required T Function(Map<String, dynamic> json) fromJson,
    required List<T> Function(SpotubeSearchResponseObject all) fromAll,
  }) async {
    if (query.isEmpty) {
      return SpotubePaginationResponseObject<T>(
        items: [],
        total: 0,
        limit: limit ?? 20,
        hasMore: false,
        nextOffset: null,
      );
    }

    return searchPageWithFallback<T>(
      label: "$funcName \"$query\"",
      offset: offset ?? 0,
      limit: limit ?? 20,
      page: () async {
        final raw = await hetuMetadataSearch.invokeWithRetry(
          funcName,
          positionalArgs: [query],
          namedArgs: {
            "limit": limit,
            "offset": offset,
          }..removeWhere((key, value) => value == null),
        ) as Map;
        return SpotubePaginationResponseObject<T>.fromJson(
          raw.cast<String, dynamic>(),
          (json) => fromJson(json.cast<String, dynamic>()),
        );
      },
      fromAll: () async => fromAll(await all(query)),
    );
  }

  Future<SpotubePaginationResponseObject<SpotubeSimpleAlbumObject>> albums(
    String query, {
    int? limit,
    int? offset,
  }) {
    return _page(
      "albums",
      query,
      limit: limit,
      offset: offset,
      fromJson: SpotubeSimpleAlbumObject.fromJson,
      fromAll: (all) => all.albums,
    );
  }

  Future<SpotubePaginationResponseObject<SpotubeFullArtistObject>> artists(
    String query, {
    int? limit,
    int? offset,
  }) {
    return _page(
      "artists",
      query,
      limit: limit,
      offset: offset,
      fromJson: SpotubeFullArtistObject.fromJson,
      fromAll: (all) => all.artists,
    );
  }

  Future<SpotubePaginationResponseObject<SpotubeSimplePlaylistObject>>
      playlists(
    String query, {
    int? limit,
    int? offset,
  }) {
    return _page(
      "playlists",
      query,
      limit: limit,
      offset: offset,
      fromJson: SpotubeSimplePlaylistObject.fromJson,
      fromAll: (all) => all.playlists,
    );
  }

  Future<SpotubePaginationResponseObject<SpotubeFullTrackObject>> tracks(
    String query, {
    int? limit,
    int? offset,
  }) {
    return _page(
      "tracks",
      query,
      limit: limit,
      offset: offset,
      fromJson: SpotubeFullTrackObject.fromJson,
      fromAll: (all) => all.tracks,
    );
  }
}

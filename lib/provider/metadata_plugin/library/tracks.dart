import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/provider/metadata_plugin/core/auth.dart';
import 'package:spotube/provider/metadata_plugin/metadata_plugin_provider.dart';
import 'package:spotube/provider/metadata_plugin/utils/common.dart';
import 'package:spotube/provider/metadata_plugin/utils/paginated.dart';
import 'package:spotube/services/logger/logger.dart';

class MetadataPluginSavedTracksNotifier
    extends AutoDisposePaginatedAsyncNotifier<SpotubeFullTrackObject> {
  MetadataPluginSavedTracksNotifier() : super();

  @override
  fetch(offset, limit) async {
    final tracks = await (await metadataPlugin).user.savedTracks(
          offset: offset,
          limit: limit,
        );

    return tracks;
  }

  @override
  build() async {
    ref.cacheFor();

    await ref.watch(metadataPluginAuthenticatedProvider.future);
    return await fetch(0, 50);
  }

  Future<void> addFavorite(List<SpotubeTrackObject> tracks) async {
    if (state.value == null) {
      return;
    }

    final oldState = state.value;
    state = AsyncData(
      state.value!.copyWith(
        items: [
          ...tracks.whereType<SpotubeFullTrackObject>(),
          ...state.value!.items
        ],
      ),
    );

    try {
      await (await metadataPlugin).track.save(tracks.map((e) => e.id).toList());
      ref.read(likedTrackIdsProvider.notifier).mark(tracks, liked: true);
      for (final track in tracks) {
        ref.invalidate(metadataPluginIsSavedTrackProvider(track.id));
      }
    } catch (e) {
      state = AsyncData(oldState!);
      rethrow;
    }
  }

  Future<void> removeFavorite(List<SpotubeTrackObject> tracks) async {
    if (state.value == null) {
      return;
    }

    final oldState = state.value;
    state = AsyncData(
      state.value!.copyWith(
        items: state.value!.items
            .where(
              (savedTrack) => !tracks.any((track) => track.id == savedTrack.id),
            )
            .toList(),
      ),
    );

    try {
      await (await metadataPlugin)
          .track
          .unsave(tracks.map((e) => e.id).toList());
      ref.read(likedTrackIdsProvider.notifier).mark(tracks, liked: false);
      for (final track in tracks) {
        ref.invalidate(metadataPluginIsSavedTrackProvider(track.id));
      }
    } catch (e) {
      state = AsyncData(oldState!);
      rethrow;
    }
  }
}

final metadataPluginSavedTracksProvider = AutoDisposeAsyncNotifierProvider<
    MetadataPluginSavedTracksNotifier,
    SpotubePaginationResponseObject<SpotubeFullTrackObject>>(
  () => MetadataPluginSavedTracksNotifier(),
);

/// Every track id in Liked Songs, loaded page by page in the background.
///
/// Local change: the plugin's `isSavedTracks` asks Spotify "isCurated", which
/// is true for a song saved to ANY of your playlists, not only Liked Songs. So
/// the only correct answer is the Liked Songs list itself. It is loaded once
/// per launch (50 per page, paced so Spotify does not rate-limit us) and kept
/// up to date by [MetadataPluginSavedTracksNotifier.addFavorite]/[removeFavorite].
typedef LikedTrackIds = ({Set<String> ids, bool complete});

class LikedTrackIdsNotifier extends Notifier<LikedTrackIds> {
  static const _pageSize = 50;
  static const _pause = Duration(milliseconds: 700);

  // Bumped on every rebuild so a stale loading loop stops itself.
  int _generation = 0;

  @override
  LikedTrackIds build() {
    final authenticated =
        ref.watch(metadataPluginAuthenticatedProvider).asData?.value ?? false;
    final generation = ++_generation;
    if (authenticated) _load(generation);
    return (ids: <String>{}, complete: false);
  }

  Future<void> _load(int generation) async {
    var offset = 0;
    while (generation == _generation) {
      try {
        final plugin = await ref.read(metadataPluginProvider.future);
        if (plugin == null) return;
        final page =
            await plugin.user.savedTracks(offset: offset, limit: _pageSize);
        if (generation != _generation) return;
        state = (
          ids: {...state.ids, ...page.items.map((t) => t.id)},
          complete: !page.hasMore,
        );
        if (!page.hasMore) {
          AppLogger.log.i("Liked Songs loaded: ${state.ids.length} tracks");
          return;
        }
        offset = page.nextOffset ?? offset + page.items.length;
      } catch (e, stack) {
        // invokeWithRetry already retried; wait and try the same page again.
        AppLogger.reportError(e, stack);
        await Future.delayed(const Duration(seconds: 30));
        continue;
      }
      await Future.delayed(_pause);
    }
  }

  void mark(List<SpotubeTrackObject> tracks, {required bool liked}) {
    final ids = {...state.ids};
    for (final track in tracks) {
      liked ? ids.add(track.id) : ids.remove(track.id);
    }
    state = (ids: ids, complete: state.complete);
  }

  /// The heart in track rows: flips straight away, undoes it if Spotify
  /// refuses, and refreshes the Liked Songs page.
  Future<void> toggle(SpotubeTrackObject track) async {
    final liked = state.ids.contains(track.id);
    mark([track], liked: !liked);
    try {
      final plugin = await ref.read(metadataPluginProvider.future);
      if (liked) {
        await plugin!.track.unsave([track.id]);
      } else {
        await plugin!.track.save([track.id]);
      }
      ref.invalidate(metadataPluginSavedTracksProvider);
    } catch (e, stack) {
      mark([track], liked: liked);
      AppLogger.reportError(e, stack);
    }
  }
}

final likedTrackIdsProvider =
    NotifierProvider<LikedTrackIdsNotifier, LikedTrackIds>(
  LikedTrackIdsNotifier.new,
);

/// Cheap per-row check for the heart in track lists. False until known.
final isTrackLikedProvider = Provider.autoDispose.family<bool, String>(
  (ref, trackId) =>
      ref.watch(likedTrackIdsProvider.select((s) => s.ids.contains(trackId))),
);

final metadataPluginIsSavedTrackProvider =
    FutureProvider.autoDispose.family<bool, String>(
  (ref, trackId) {
    final liked = ref.watch(likedTrackIdsProvider);
    if (liked.ids.contains(trackId)) return true;
    if (liked.complete) return false;
    // Still loading Liked Songs: stay "loading". This provider re-runs when
    // the list grows or finishes, and that run gives the real answer.
    return Completer<bool>().future;
  },
);

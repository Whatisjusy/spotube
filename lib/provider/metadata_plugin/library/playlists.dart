import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/provider/metadata_plugin/core/auth.dart';
import 'package:spotube/provider/metadata_plugin/metadata_plugin_provider.dart';
import 'package:spotube/provider/metadata_plugin/tracks/playlist.dart';
import 'package:spotube/provider/metadata_plugin/utils/paginated.dart';
import 'package:spotube/services/logger/logger.dart';
import 'package:spotube/services/metadata/errors/exceptions.dart';

class MetadataPluginSavedPlaylistsNotifier
    extends PaginatedAsyncNotifier<SpotubeSimplePlaylistObject> {
  MetadataPluginSavedPlaylistsNotifier() : super();

  @override
  fetch(int offset, int limit) async {
    final playlists = await (await metadataPlugin)
        .user
        .savedPlaylists(limit: limit, offset: offset);

    return playlists;
  }

  @override
  build() async {
    await ref.watch(metadataPluginAuthenticatedProvider.future);

    final playlists = await fetch(0, 20);

    return playlists;
  }

  void updatePlaylist(SpotubeSimplePlaylistObject playlist) {
    if (state.value == null) return;

    if (state.value!.items.none((e) => e.id == playlist.id)) return;

    state = AsyncData(
      state.value!.copyWith(
        items: state.value!.items
            .map((element) => element.id == playlist.id ? playlist : element)
            .toList(),
      ),
    );
  }

  Future<void> addFavorite(SpotubeSimplePlaylistObject playlist) async {
    if (state.value == null) return;

    final oldState = state.value;

    state = AsyncData(
      state.value!.copyWith(
        items: [
          playlist,
          ...state.value!.items,
        ],
      ),
    );

    try {
      await (await metadataPlugin).playlist.save(playlist.id);
      // Local change: through the container. The saved check now watches
      // this list, and ref.invalidate's debug check calls that circular, so
      // in debug builds a follow that worked was undone on screen (Mac,
      // 2026-10-21). Release builds skip that check.
      ref.container
          .invalidate(metadataPluginIsSavedPlaylistProvider(playlist.id));
    } catch (e) {
      state = AsyncData(oldState!);
      rethrow;
    }
  }

  Future<void> removeFavorite(SpotubeSimplePlaylistObject playlist) async {
    if (state.value == null) return;

    final oldState = state.value;
    state = AsyncData(
      state.value!.copyWith(
        items: state.value!.items.where((e) => (e).id != playlist.id).toList(),
      ),
    );

    try {
      await (await metadataPlugin).playlist.unsave(playlist.id);
      ref.container
          .invalidate(metadataPluginIsSavedPlaylistProvider(playlist.id));
    } catch (e) {
      state = AsyncData(oldState!);
      rethrow;
    }
  }

  Future<void> delete(String playlistId) async {
    if (state.value == null) return;
    final oldState = state;
    try {
      state = const AsyncLoading();
      await (await metadataPlugin).playlist.deletePlaylist(playlistId);
      ref.invalidateSelf();
      ref.container
          .invalidate(metadataPluginIsSavedPlaylistProvider(playlistId));
      ref.invalidate(metadataPluginPlaylistTracksProvider(playlistId));
    } catch (e) {
      state = oldState;
      rethrow;
    }
  }

  Future<void> addTracks(String playlistId, List<String> trackIds) async {
    if (state.value == null) return;

    await (await metadataPlugin)
        .playlist
        .addTracks(playlistId, trackIds: trackIds);

    ref.invalidate(metadataPluginPlaylistTracksProvider(playlistId));
  }

  Future<void> removeTracks(String playlistId, List<String> trackIds) async {
    if (state.value == null) return;

    await (await metadataPlugin)
        .playlist
        .removeTracks(playlistId, trackIds: trackIds);

    ref.invalidate(metadataPluginPlaylistTracksProvider(playlistId));
  }
}

final metadataPluginSavedPlaylistsProvider = AsyncNotifierProvider<
    MetadataPluginSavedPlaylistsNotifier,
    SpotubePaginationResponseObject<SpotubeSimplePlaylistObject>>(
  () => MetadataPluginSavedPlaylistsNotifier(),
);

final metadataPluginIsSavedPlaylistProvider =
    FutureProvider.family<bool, String>(
  (ref, id) async {
    final plugin = await ref.watch(metadataPluginProvider.future);

    if (plugin == null) {
      throw MetadataPluginException.noDefaultMetadataPlugin();
    }

    // Local change: answer from the Library playlists list, paging through
    // the rest of it here when needed. That list comes from Spotify's query
    // server; the plugin's own check asks the old API, which Spotify refuses
    // (see SpotifyGql): live on the Mac, 2026-10-21, it failed after 87-120 s
    // of retries every time, and the playlist page's heart never appeared.
    // The extra pages are not added to the shared list: changing a list this
    // provider watches would make it rebuild itself, and that rebuild waits
    // for the next frame (6 minutes in a hidden window).
    try {
      final (found, hasMore, nextOffset) = await ref.watch(
        metadataPluginSavedPlaylistsProvider.selectAsync(
          (value) => (
            value.items.any((e) => e.id == id),
            value.hasMore,
            value.nextOffset,
          ),
        ),
      );
      if (found) return true;
      if (!hasMore) return false;
      var offset = nextOffset ?? 0;
      while (true) {
        final page =
            await plugin.user.savedPlaylists(offset: offset, limit: 50);
        if (page.items.any((e) => e.id == id)) return true;
        if (!page.hasMore || page.items.isEmpty) return false;
        offset = page.nextOffset ?? offset + page.items.length;
      }
    } catch (e) {
      AppLogger.log.w("Saved check for playlist $id: the Library list "
          "failed, asking the plugin: $e");
      return await plugin.user.isSavedPlaylist(id);
    }
  },
);

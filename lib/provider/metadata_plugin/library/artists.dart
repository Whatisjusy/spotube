import 'package:riverpod/riverpod.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/provider/metadata_plugin/core/auth.dart';
import 'package:spotube/provider/metadata_plugin/utils/paginated.dart';
import 'package:spotube/provider/metadata_plugin/metadata_plugin_provider.dart';
import 'package:spotube/provider/metadata_plugin/utils/common.dart';

class MetadataPluginSavedArtistNotifier
    extends PaginatedAsyncNotifier<SpotubeFullArtistObject> {
  @override
  Future<SpotubePaginationResponseObject<SpotubeFullArtistObject>> fetch(
    int offset,
    int limit,
  ) async {
    final artists = await (await metadataPlugin).user.savedArtists(
          limit: limit,
          offset: offset,
        );

    return artists;
  }

  @override
  build() async {
    await ref.watch(metadataPluginAuthenticatedProvider.future);
    return await fetch(0, 20);
  }

  Future<void> addFavorite(List<SpotubeFullArtistObject> artists) async {
    if (artists.isEmpty || state.value == null) return;
    final oldState = state.value;

    state = AsyncData(
      state.value!.copyWith(
        items: [
          ...artists,
          ...state.value!.items,
        ],
      ),
    );
    try {
      await (await metadataPlugin)
          .artist
          .save(artists.map((e) => e.id).toList());
      for (final artist in artists) {
        ref.invalidate(metadataPluginIsSavedArtistProvider(artist.id));
      }
    } catch (e) {
      state = AsyncData(oldState!);
      rethrow;
    }
  }

  Future<void> removeFavorite(List<SpotubeFullArtistObject> artists) async {
    if (artists.isEmpty || state.value == null) return;

    final oldState = state.value;

    final artistIds = artists.map((e) => e.id).toList();
    state = AsyncData(
      state.value!.copyWith(
        items: state.value!.items
            .where(
              (e) => artistIds.contains((e).id) == false,
            )
            .toList(),
      ),
    );

    try {
      await (await metadataPlugin).artist.unsave(artistIds);
      for (final id in artistIds) {
        ref.invalidate(metadataPluginIsSavedArtistProvider(id));
      }
    } catch (e) {
      state = AsyncData(oldState!);
      rethrow;
    }
  }
}

final metadataPluginSavedArtistsProvider = AsyncNotifierProvider<
    MetadataPluginSavedArtistNotifier,
    SpotubePaginationResponseObject<SpotubeFullArtistObject>>(
  () => MetadataPluginSavedArtistNotifier(),
);

final metadataPluginIsSavedArtistProvider =
    FutureProvider.autoDispose.family<bool, String>(
  (ref, artistId) async {
    ref.cacheFor();
    // Local change: answer from what is already loaded, otherwise ask the
    // API about this one artist instead of downloading the whole library.
    final loaded = ref.watch(metadataPluginSavedArtistsProvider).asData?.value;
    if (loaded != null) {
      if (loaded.items.any((element) => element.id == artistId)) return true;
      if (!loaded.hasMore) return false;
    }
    final plugin = await ref.watch(metadataPluginProvider.future);
    if (plugin == null) return false;
    final result = await plugin.user.isSavedArtists([artistId]);
    return result.firstOrNull ?? false;
  },
);

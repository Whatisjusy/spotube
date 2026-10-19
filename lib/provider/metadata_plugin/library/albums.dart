import 'package:riverpod/riverpod.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/provider/metadata_plugin/core/auth.dart';
import 'package:spotube/provider/metadata_plugin/utils/paginated.dart';
import 'package:spotube/provider/metadata_plugin/metadata_plugin_provider.dart';
import 'package:spotube/provider/metadata_plugin/utils/common.dart';

class MetadataPluginSavedAlbumNotifier
    extends PaginatedAsyncNotifier<SpotubeSimpleAlbumObject> {
  @override
  Future<SpotubePaginationResponseObject<SpotubeSimpleAlbumObject>> fetch(
    int offset,
    int limit,
  ) async {
    return await (await metadataPlugin).user.savedAlbums(
          limit: limit,
          offset: offset,
        );
  }

  @override
  build() async {
    await ref.watch(metadataPluginAuthenticatedProvider.future);
    return await fetch(0, 20);
  }

  Future<void> addFavorite(List<SpotubeSimpleAlbumObject> albums) async {
    if (albums.isEmpty || state.value == null) return;
    final oldState = state.value;

    state = AsyncData(
      state.value!.copyWith(
        items: [
          ...albums,
          ...state.value!.items,
        ],
      ),
    );
    try {
      await (await metadataPlugin).album.save(albums.map((e) => e.id).toList());
      for (final album in albums) {
        ref.invalidate(metadataPluginIsSavedAlbumProvider(album.id));
      }
    } catch (e) {
      state = AsyncData(oldState!);
      rethrow;
    }
  }

  Future<void> removeFavorite(List<SpotubeSimpleAlbumObject> albums) async {
    if (albums.isEmpty || state.value == null) return;

    final oldState = state.value;

    final albumIds = albums.map((e) => e.id).toList();
    state = AsyncData(
      state.value!.copyWith(
        items: state.value!.items
            .where(
              (e) => albumIds.contains((e).id) == false,
            )
            .toList(),
      ),
    );
    try {
      await (await metadataPlugin).album.unsave(albumIds);
      for (final id in albumIds) {
        ref.invalidate(metadataPluginIsSavedAlbumProvider(id));
      }
    } catch (e) {
      state = AsyncData(oldState!);
      rethrow;
    }
  }
}

final metadataPluginSavedAlbumsProvider = AsyncNotifierProvider<
    MetadataPluginSavedAlbumNotifier,
    SpotubePaginationResponseObject<SpotubeSimpleAlbumObject>>(
  () => MetadataPluginSavedAlbumNotifier(),
);

final metadataPluginIsSavedAlbumProvider =
    FutureProvider.autoDispose.family<bool, String>(
  (ref, albumId) async {
    ref.cacheFor();
    // Local change: answer from what is already loaded, otherwise ask the
    // API about this one album instead of downloading the whole library.
    final loaded = ref.watch(metadataPluginSavedAlbumsProvider).asData?.value;
    if (loaded != null) {
      if (loaded.items.any((element) => element.id == albumId)) return true;
      if (!loaded.hasMore) return false;
    }
    final plugin = await ref.watch(metadataPluginProvider.future);
    if (plugin == null) return false;
    final result = await plugin.user.isSavedAlbums([albumId]);
    return result.firstOrNull ?? false;
  },
);

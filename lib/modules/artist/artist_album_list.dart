import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:spotube/components/horizontal_playbutton_card_view/horizontal_playbutton_card_view.dart';
import 'package:spotube/extensions/context.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/provider/metadata_plugin/artist/albums.dart';
import 'package:spotube/provider/metadata_plugin/artist/artist.dart';
import 'package:spotube/provider/metadata_plugin/utils/common.dart';

/// The Spotify plugin's artist album list leaves out the albums' artists, so
/// the album page had no artist to show. Fill in the artist whose page this is.
List<SpotubeSimpleAlbumObject> albumsWithArtist(
  List<SpotubeSimpleAlbumObject> albums,
  SpotubeFullArtistObject? artist,
) {
  if (artist == null) return albums;
  return albums.map((album) {
    if (album.artists.isNotEmpty) return album;
    return album.copyWith(
      artists: [
        SpotubeSimpleArtistObject(
          id: artist.id,
          name: artist.name,
          externalUri: artist.externalUri,
          images: artist.images,
        ),
      ],
    );
  }).toList();
}

class ArtistAlbumList extends HookConsumerWidget {
  final String artistId;

  const ArtistAlbumList(
    this.artistId, {
    super.key,
  });

  @override
  Widget build(BuildContext context, ref) {
    final albumsQuery = ref.watch(metadataPluginArtistAlbumsProvider(artistId));
    final albumsQueryNotifier =
        ref.watch(metadataPluginArtistAlbumsProvider(artistId).notifier);

    final artist =
        ref.watch(metadataPluginArtistProvider(artistId)).asData?.value;

    final albums = albumsWithArtist(
      albumsQuery.asData?.value.items ?? [],
      artist,
    );

    final theme = Theme.of(context);

    return HorizontalPlaybuttonCardView<SpotubeSimpleAlbumObject>(
      isLoadingNextPage: albumsQuery.isLoadingNextPage,
      hasNextPage: albumsQuery.asData?.value.hasMore ?? false,
      items: albums,
      onFetchMore: albumsQueryNotifier.fetchMore,
      title: Text(
        context.l10n.albums,
        style: theme.typography.h4,
      ),
    );
  }
}

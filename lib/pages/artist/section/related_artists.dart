import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:shadcn_flutter/shadcn_flutter_extension.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:spotube/extensions/context.dart';
import 'package:spotube/modules/artist/artist_card.dart';
import 'package:spotube/provider/metadata_plugin/artist/related.dart';

/// "Fans also like", heading included. Shows nothing when Spotify has no
/// answer: the error text it used to show was a raw 429 message.
class ArtistPageRelatedArtists extends ConsumerWidget {
  final String artistId;
  const ArtistPageRelatedArtists({
    super.key,
    required this.artistId,
  });

  @override
  Widget build(BuildContext context, ref) {
    final relatedArtists =
        ref.watch(metadataPluginArtistRelatedArtistsProvider(artistId));

    final body = switch (relatedArtists) {
      AsyncData(value: final artists) when artists.items.isNotEmpty =>
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 8.0),
          sliver: SliverGrid.builder(
            itemCount: artists.items.length,
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 200,
              mainAxisExtent: 250,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 0.8,
            ),
            itemBuilder: (context, index) {
              final artist = artists.items.elementAt(index);
              return SizedBox(
                width: 180,
                child: ArtistCard(artist),
              );
            },
          ),
        ),
      AsyncLoading() => const SliverToBoxAdapter(
          child: Center(child: CircularProgressIndicator()),
        ),
      _ => null,
    };

    if (body == null) return const SliverToBoxAdapter(child: SizedBox());

    return SliverMainAxisGroup(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.all(8.0),
          sliver: SliverToBoxAdapter(
            child: Text(
              context.l10n.fans_also_like,
              style: context.theme.typography.h4,
            ),
          ),
        ),
        body,
      ],
    );
  }
}

import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:spotube/components/dialogs/select_device_dialog.dart';
import 'package:spotube/components/track_presentation/use_track_tile_play_callback.dart';
import 'package:spotube/components/track_tile/track_tile.dart';
import 'package:spotube/models/connect/connect.dart';
import 'package:spotube/provider/audio_player/audio_player.dart';
import 'package:spotube/provider/connect/connect.dart';
import 'package:spotube/provider/metadata_plugin/artist/artist.dart';
import 'package:spotube/provider/metadata_plugin/library/tracks.dart';

/// Local change: the songs from this artist that are in your Liked Songs,
/// shown under the artist's name. Hidden when there are none.
class ArtistPageLikedTracks extends HookConsumerWidget {
  /// How many rows show before "Show all".
  static const _collapsedCount = 5;

  final String artistId;
  const ArtistPageLikedTracks({super.key, required this.artistId});

  @override
  Widget build(BuildContext context, ref) {
    final theme = Theme.of(context);
    final expanded = useState(false);

    final playlist = ref.watch(audioPlayerProvider);
    final playlistNotifier = ref.watch(audioPlayerProvider.notifier);
    final liked = ref.watch(artistLikedTracksProvider(artistId));
    final artistName =
        ref.watch(metadataPluginArtistProvider(artistId)).asData?.value.name;

    final tracks = liked.tracks;
    if (tracks.isEmpty) return const SliverToBoxAdapter();

    final shown = expanded.value || tracks.length <= _collapsedCount
        ? tracks
        : tracks.take(_collapsedCount).toList();

    // "Play from here", like other collection lists.
    Future<void> playFrom(int index) async {
      final queue = tracks.skip(index).take(kQueueWindow + 1).toList();
      final isRemoteDevice = await showSelectDeviceDialog(context, ref);
      if (isRemoteDevice == null) return;
      if (isRemoteDevice) {
        await ref.read(connectProvider.notifier).load(
              WebSocketLoadEventData.playlist(
                tracks: queue,
                collection: null,
                initialIndex: 0,
              ),
            );
      } else {
        await playlistNotifier.load(queue, initialIndex: 0, autoPlay: true);
      }
    }

    final count = "${tracks.length} song${tracks.length == 1 ? "" : "s"}";
    final subtitle = artistName == null
        ? "You've liked $count"
        : "You've liked $count by $artistName";

    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(8.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("Liked songs", style: theme.typography.h4),
                Text(
                  liked.complete ? subtitle : "$subtitle so far",
                ).muted().small(),
              ],
            ),
          ),
        ),
        SliverList.builder(
          itemCount: shown.length,
          itemBuilder: (context, index) {
            return TrackTile(
              index: index,
              playlist: playlist,
              track: shown[index],
              onTap: () => playFrom(index),
            );
          },
        ),
        if (tracks.length > _collapsedCount)
          SliverToBoxAdapter(
            child: Align(
              alignment: Alignment.centerLeft,
              child: Button.ghost(
                onPressed: () => expanded.value = !expanded.value,
                child: Text(
                  expanded.value ? "Show less" : "Show all ${tracks.length}",
                ),
              ),
            ),
          ),
        const SliverGap(20),
      ],
    );
  }
}

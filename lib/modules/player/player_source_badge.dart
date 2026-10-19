import 'package:auto_route/auto_route.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:spotube/collections/routes.gr.dart';
import 'package:spotube/extensions/constrains.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/modules/player/sibling_tracks_sheet.dart';
import 'package:spotube/provider/audio_player/audio_player.dart';
import 'package:spotube/provider/server/sourced_track_provider.dart';
import 'package:spotube/services/sourced_track/source_label.dart';

/// Pill next to the Now Playing title showing the playing format. Red when
/// the matched title looks like a music video. Tap opens the alternative
/// sources sheet so the listener can swap.
class PlayerSourceBadge extends ConsumerWidget {
  final bool floating;
  const PlayerSourceBadge({super.key, this.floating = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activeTrack =
        ref.watch(audioPlayerProvider.select((s) => s.activeTrack));
    if (activeTrack is! SpotubeFullTrackObject) {
      return const SizedBox.shrink();
    }

    final sourced = ref.watch(sourcedTrackProvider(activeTrack)).asData?.value;
    final stream = sourced?.activeStream;
    if (sourced == null || stream == null) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final label = Text(
      sourceLabel(stream),
      style: theme.typography.xSmall,
      overflow: TextOverflow.ellipsis,
    );

    void open() {
      if (MediaQuery.sizeOf(context).mdAndUp) {
        showPopover(
          alignment: Alignment.bottomCenter,
          context: context,
          builder: (context) => SurfaceCard(
            padding: EdgeInsets.zero,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 600, maxWidth: 500),
              child: SiblingTracksSheet(floating: floating),
            ),
          ),
        );
      } else {
        context.pushRoute(const PlayerTrackSourcesRoute());
      }
    }

    final badge = looksLikeMusicVideo(sourced.info.title)
        ? DestructiveBadge(onPressed: open, child: label)
        : SecondaryBadge(onPressed: open, child: label);

    return Tooltip(
      tooltip: TooltipContainer(
        child: Text(
          "${sourced.info.title}\n${sourced.info.artists.join(", ")}\n${sourced.info.id}",
        ),
      ).call,
      child: badge,
    );
  }
}

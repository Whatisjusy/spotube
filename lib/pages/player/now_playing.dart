// Local addition (Everforest look, 2026-10-20): a full-size Now Playing page
// for desktop layouts. Blurred album art behind, big artwork and title on the
// left, lyrics or the queue on the right. Opened by clicking the artwork in
// the bottom player bar. The bottom bar keeps the transport controls.

import 'dart:ui' show ImageFilter;

import 'package:auto_route/auto_route.dart';
import 'package:auto_size_text/auto_size_text.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:palette_generator/palette_generator.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'package:spotube/collections/assets.gen.dart';
import 'package:spotube/collections/routes.gr.dart';
import 'package:spotube/collections/spotube_icons.dart';
import 'package:spotube/components/image/universal_image.dart';
import 'package:spotube/components/links/artist_link.dart';
import 'package:spotube/extensions/context.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/modules/player/player_actions.dart';
import 'package:spotube/modules/player/player_queue.dart';
import 'package:spotube/modules/player/player_source_badge.dart';
import 'package:spotube/pages/lyrics/synced_lyrics.dart';
import 'package:spotube/provider/audio_player/audio_player.dart';
import 'package:spotube/provider/metadata_plugin/audio_source/quality_label.dart';

@RoutePage()
class NowPlayingPage extends HookConsumerWidget {
  static const name = "now-playing";

  const NowPlayingPage({super.key});

  @override
  Widget build(BuildContext context, ref) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final playback = ref.watch(audioPlayerProvider);
    final playbackNotifier = ref.read(audioPlayerProvider.notifier);
    final track = playback.activeTrack;
    final isLocalTrack = track is SpotubeLocalTrackObject;
    final qualityLabel = ref.watch(audioSourceQualityLabelProvider);
    final tab = useState(0);

    final albumArt = useMemoized(
      () => (track?.album.images).asUrlString(
        placeholder: ImagePlaceholder.albumArt,
      ),
      [track?.album.images],
    );

    // Lyrics colour themselves from a palette; give them the page's own
    // background so they read as cream on green, not as album colours.
    final lyricsPalette = PaletteColor(colorScheme.background, 1);

    final artSide = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420, maxHeight: 420),
          child: AspectRatio(
            aspectRatio: 1,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(theme.radiusLg),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: .45),
                    blurRadius: 40,
                    offset: const Offset(0, 16),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(theme.radiusLg),
                child: UniversalImage(
                  path: albumArt,
                  placeholder: Assets.images.albumPlaceholder.path,
                  fit: BoxFit.cover,
                ),
              ),
            ),
          ),
        ),
        const Gap(28),
        AutoSizeText(
          track?.name ?? context.l10n.not_playing,
          style: theme.typography.h1,
          maxLines: 2,
          minFontSize: 22,
          overflow: TextOverflow.ellipsis,
        ),
        const Gap(6),
        if (isLocalTrack)
          Text(
            track.artists.asString(),
            style: theme.typography.large
                .copyWith(color: colorScheme.mutedForeground),
          )
        else
          ArtistLink(
            artists: track?.artists ?? [],
            textStyle: theme.typography.large
                .copyWith(color: colorScheme.mutedForeground),
            onRouteChange: (route) => context.router.navigateNamed(route),
            onOverflowArtistClick: () {
              if (track != null) {
                context.navigateTo(TrackRoute(trackId: track.id));
              }
            },
          ),
        const Gap(16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const PlayerSourceBadge(),
            OutlineBadge(
              leading: const Icon(SpotubeIcons.lightningOutlined),
              child: Text(qualityLabel),
            ),
          ],
        ),
        const Gap(12),
        const PlayerActions(
          mainAxisAlignment: MainAxisAlignment.start,
          showQueue: false,
        ),
      ],
    );

    final panelSide = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Tabs(
          index: tab.value,
          onChanged: (i) => tab.value = i,
          children: [
            TabItem(child: Text(context.l10n.lyrics)),
            TabItem(child: Text(context.l10n.queue)),
          ],
        ),
        const Gap(12),
        Expanded(
          child: Container(
            clipBehavior: Clip.hardEdge,
            decoration: BoxDecoration(
              color: colorScheme.card.withValues(alpha: .85),
              borderRadius: BorderRadius.circular(theme.radiusLg),
              border: Border.all(color: colorScheme.border),
            ),
            child: IndexedStack(
              index: tab.value,
              children: [
                SyncedLyrics(palette: lyricsPalette, isModal: false),
                PlayerQueue.fromAudioPlayerNotifier(
                  floating: false,
                  playlist: playback,
                  notifier: playbackNotifier,
                ),
              ],
            ),
          ),
        ),
      ],
    );

    return Scaffold(
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Backdrop: the album art, blurred and dimmed (Monochrome/Feishin).
          ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 50, sigmaY: 50),
            child: UniversalImage(
              path: albumArt,
              placeholder: Assets.images.albumPlaceholder.path,
              fit: BoxFit.cover,
            ),
          ),
          ColoredBox(color: colorScheme.background.withValues(alpha: .72)),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(32, 24, 32, 24),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final narrow = constraints.maxWidth < 900;
                  if (narrow) {
                    return ListView(
                      children: [
                        artSide,
                        const Gap(24),
                        SizedBox(height: 520, child: panelSide),
                      ],
                    );
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        flex: 4,
                        child: SingleChildScrollView(child: artSide),
                      ),
                      const Gap(40),
                      Expanded(flex: 5, child: panelSide),
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

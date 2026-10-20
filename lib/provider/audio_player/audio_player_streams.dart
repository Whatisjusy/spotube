import 'dart:async';
import 'dart:math';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/provider/audio_player/audio_player.dart';
import 'package:spotube/provider/audio_player/state.dart';
import 'package:spotube/provider/discord_provider.dart';
import 'package:spotube/provider/history/history.dart';
import 'package:spotube/provider/metadata_plugin/core/scrobble.dart';
import 'package:spotube/provider/metadata_plugin/metadata_plugin_provider.dart';
import 'package:spotube/provider/server/routes/playback.dart';
import 'package:spotube/provider/server/sourced_track_provider.dart';
import 'package:spotube/provider/skip_segments/skip_segments.dart';
import 'package:spotube/provider/scrobbler/scrobbler.dart';
import 'package:spotube/provider/user_preferences/user_preferences_provider.dart';
import 'package:spotube/services/audio_player/audio_player.dart';
import 'package:spotube/services/audio_services/audio_services.dart';
import 'package:spotube/services/logger/logger.dart';
import 'package:spotube/services/sourced_track/sourced_track.dart';

class AudioPlayerStreamListeners {
  final Ref ref;
  late final AudioServices notificationService;
  AudioPlayerStreamListeners(this.ref) {
    AudioServices.create(ref, ref.read(audioPlayerProvider.notifier)).then(
      (value) => notificationService = value,
    );

    listenToActiveTrack();
    listenToQueueChanges();

    final subscriptions = [
      subscribeToSkipSponsor(),
      subscribeToScrobbleChanged(),
      subscribeToPosition(),
      subscribeToDuration(),
      subscribeToPlayerError(),
    ];

    ref.onDispose(() {
      for (final subscription in subscriptions) {
        subscription.cancel();
      }
    });
  }

  ScrobblerNotifier get scrobbler => ref.read(scrobblerProvider.notifier);
  UserPreferences get preferences => ref.read(userPreferencesProvider);
  DiscordNotifier get discord => ref.read(discordProvider.notifier);
  AudioPlayerState get audioPlayerState => ref.read(audioPlayerProvider);
  PlaybackHistoryActions get history =>
      ref.read(playbackHistoryActionsProvider);

  /// Keeps the system Now Playing widget and Discord in sync with whatever
  /// the app considers the active track, whichever path changed it.
  void listenToActiveTrack() {
    ref.listen(
      audioPlayerProvider.select((s) => s.activeTrack),
      (previous, track) {
        if (track == null) return;
        try {
          notificationService.addTrack(track);
          discord.updatePresence(track);
        } catch (e, stack) {
          AppLogger.reportError(e, stack);
        }
      },
    );
  }

  StreamSubscription subscribeToSkipSponsor() {
    return audioPlayer.positionStream.listen((position) async {
      try {
        final currentSegments = await ref.read(segmentProvider.future);

        if (currentSegments?.segments.isNotEmpty != true ||
            position < const Duration(seconds: 3)) {
          return;
        }

        for (final segment in currentSegments!.segments) {
          final seconds = position.inSeconds;

          if (seconds < segment.start || seconds >= segment.end) continue;

          await audioPlayer.seek(Duration(seconds: segment.end + 1));
        }
      } catch (e, stack) {
        AppLogger.reportError(e, stack);
      }
    });
  }

  StreamSubscription subscribeToScrobbleChanged() {
    String? lastScrobbled;
    return audioPlayer.positionStream.listen((position) async {
      try {
        final uid = audioPlayerState.activeTrack is SpotubeLocalTrackObject
            ? (audioPlayerState.activeTrack as SpotubeLocalTrackObject).path
            : audioPlayerState.activeTrack?.id;

        /// According to Listenbrainz and Last.fm, a scrobble should be sent
        /// after 4 minutes of listening or 50% of the track duration,
        /// whichever is less.
        final minimumListenTime = min(audioPlayer.duration.inSeconds ~/ 2, 240);

        if (audioPlayerState.activeTrack == null ||
            lastScrobbled == uid ||
            position.inSeconds < minimumListenTime ||
            audioPlayer.duration == Duration.zero ||
            position == Duration.zero) {
          return;
        }

        scrobbler.scrobble(audioPlayerState.activeTrack!);
        ref
            .read(metadataPluginScrobbleProvider.notifier)
            .scrobble(audioPlayerState.activeTrack!);
        lastScrobbled = uid;

        /// The [Track] from Playlist.getTracks doesn't contain artist images
        /// so we need to fetch them from the API
        var activeTrack = audioPlayerState.activeTrack!;
        if (activeTrack.artists.any((a) => a.images == null)) {
          final metadataPlugin = await ref.read(metadataPluginProvider.future);
          final artists = await Future.wait(
            activeTrack.artists
                .map((artist) => metadataPlugin!.artist.getArtist(artist.id)),
          );
          activeTrack = activeTrack.copyWith(
            artists: artists
                .map((e) => SpotubeSimpleArtistObject.fromJson(e.toJson()))
                .toList(),
          );
        }

        await history.addTrack(activeTrack);
      } catch (e, stack) {
        AppLogger.reportError(e, stack);
      }
    });
  }

  /// Queue positions, relative to the playing track, whose audio source is
  /// looked up ahead of time. Order matters: the most likely switch first.
  static const _lookaheadOffsets = [1, 2, 3, -1];

  /// How many of the upcoming tracks also get their audio downloaded into
  /// the music cache, so switching to them starts straight from disk.
  static const _audioPrefetchCount = 2;

  /// Tracks already prepared this session (looked up once, success or not).
  final _preparedTrackIds = <String>{};
  bool _preparing = false;
  bool _prepareAgain = false;

  /// Is the playing track's own source lookup done? Neighbours wait for it so
  /// they never compete with the song the listener is actually waiting on.
  bool get _currentTrackReady {
    final track = audioPlayerState.activeTrack;
    if (track is! SpotubeFullTrackObject) return track != null;
    return ref.read(sourcedTrackProvider(track)).hasValue;
  }

  /// Looks up (and, for the next few, downloads) the tracks around the
  /// playing one. Safe to call often: already-prepared tracks are skipped and
  /// overlapping calls fold into one extra pass.
  Future<void> _prepareNearbyTracks() async {
    if (_preparing) {
      _prepareAgain = true;
      return;
    }
    _preparing = true;
    try {
      do {
        _prepareAgain = false;
        final index = audioPlayerState.currentIndex;
        if (index == -1 || !_currentTrackReady) break;

        for (final offset in _lookaheadOffsets) {
          // The listener moved on or edited the queue; start over from there.
          if (audioPlayerState.currentIndex != index || _prepareAgain) break;

          final tracks = audioPlayerState.tracks;
          final i = index + offset;
          if (i < 0 || i >= tracks.length) continue;
          final track = tracks[i];
          if (track is! SpotubeFullTrackObject ||
              _preparedTrackIds.contains(track.id)) {
            continue;
          }

          _preparedTrackIds.add(track.id);
          try {
            final sourced = await ref.read(sourcedTrackProvider(track).future);
            if (offset > 0 && offset <= _audioPrefetchCount) {
              _enqueueDownload(sourced);
            }
          } catch (e, stack) {
            AppLogger.reportError(e, stack);
          }
        }
      } while (_prepareAgain);
    } finally {
      _preparing = false;
    }
  }

  final _downloadQueue = <SourcedTrack>[];
  bool _downloading = false;

  /// Starts downloading straight away, one file at a time so the playing
  /// track keeps most of the bandwidth.
  void _enqueueDownload(SourcedTrack track) {
    _downloadQueue.add(track);
    if (_downloading) return;
    _downloading = true;
    unawaited(() async {
      try {
        final routes = ref.read(serverPlaybackRoutesProvider);
        while (_downloadQueue.isNotEmpty) {
          await routes.prefetchToCache(_downloadQueue.removeAt(0));
        }
      } finally {
        _downloading = false;
      }
    }());
  }

  /// Any queue edit (play next, add to queue, reorder, new queue) re-checks
  /// the neighbours straight away, even while paused.
  void listenToQueueChanges() {
    ref.listen(
      audioPlayerProvider.select((s) => s.tracks),
      (previous, tracks) => _prepareNearbyTracks(),
    );
  }

  /// The playing track has loaded (also covers a paused restore at launch).
  StreamSubscription subscribeToDuration() {
    return audioPlayer.durationStream.listen((duration) {
      if (duration > Duration.zero) _prepareNearbyTracks();
    });
  }

  /// Fallback while playing: catches a source lookup that finished after the
  /// other triggers fired. Cheap, because prepared tracks are skipped.
  StreamSubscription subscribeToPosition() {
    return audioPlayer.positionStream.listen((_) => _prepareNearbyTracks());
  }

  StreamSubscription subscribeToPlayerError() {
    return audioPlayer.errorStream.listen((event) {});
  }
}

final audioPlayerStreamListenersProvider =
    Provider<AudioPlayerStreamListeners>(AudioPlayerStreamListeners.new);

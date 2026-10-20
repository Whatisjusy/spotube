import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/provider/metadata_plugin/audio_source/quality_presets.dart';
import 'package:spotube/provider/metadata_plugin/metadata_plugin_provider.dart';
import 'package:spotube/services/logger/logger.dart';
import 'package:spotube/services/network_cost.dart';
import 'package:spotube/services/sourced_track/sourced_track.dart';

/// Flips when the phone moves between Wi-Fi and mobile data, so every song
/// is looked up again the right way (plugin and FLAC, or YouTube directly).
final _networkCostProvider =
    StreamProvider<bool>((ref) => NetworkCost.changes);

/// True only for a real quality change by the user. Presets start empty and
/// fill in when the plugin loads (and empty again if it reloads); those
/// steps are not a reason to look a song up again.
bool presetsChangeNeedsNewLookup(
  AudioSourcePresetsState? previous,
  AudioSourcePresetsState next,
) {
  if (previous == null || previous.presets.isEmpty || next.presets.isEmpty) {
    return false;
  }
  return previous.selectedStreamingContainerIndex !=
          next.selectedStreamingContainerIndex ||
      previous.selectedStreamingQualityIndex !=
          next.selectedStreamingQualityIndex;
}

/// Runs [read]; if it fails, [invalidate]s and runs it once more.
///
/// A lookup that failed stays failed in its provider. On the phone
/// (2026-10-20) a YouTube search hiccup while preparing the next songs left
/// "Deviancy" and "CLENCH MY FIST" failed, so each was skipped the moment
/// it was due, without being looked up again.
Future<T> retryFailedRead<T>({
  required Future<T> Function() read,
  required void Function() invalidate,
  required String name,
}) async {
  try {
    return await read();
  } catch (e) {
    AppLogger.log.w("Looking up \"$name\" again: the earlier lookup failed "
        "(${"$e".split("\n").first})");
    invalidate();
    return await read();
  }
}

class SourcedTrackNotifier
    extends FamilyAsyncNotifier<SourcedTrack, SpotubeFullTrackObject> {
  static final _builds = <String, int>{};

  @override
  FutureOr<SourcedTrack> build(query) {
    // Each rebuild starts a whole new lookup and the old one keeps running.
    // Watching these as plain values restarted every lookup begun during app
    // launch: once when the plugin finished loading and twice while the
    // presets loaded (seen 2026-10-20: 4 lookups, 4 YouTube searches, same
    // song, same 150 ms). So: rebuild only when the plugin is replaced
    // (`.future` changes then, not when it finishes loading), when the
    // network changes, or when the user picks another quality.
    ref.watch(audioSourcePluginProvider.future);
    ref.watch(_networkCostProvider);
    ref.listen(audioSourcePresetsProvider, (previous, next) {
      if (presetsChangeNeedsNewLookup(previous, next)) ref.invalidateSelf();
    });

    final n = _builds[query.id] = (_builds[query.id] ?? 0) + 1;
    AppLogger.log.i("Lookup #$n for \"${query.name}\"");

    return SourcedTrack.fetchFromTrack(query: query, ref: ref);
  }

  Future<SourcedTrack> refreshStreamingUrl() async {
    return await update((prev) async {
      return await prev.refreshStream();
    });
  }

  Future<SourcedTrack> copyWithSibling() async {
    return await update((prev) async {
      return prev.copyWithSibling();
    });
  }

  Future<SourcedTrack> swapWithSibling(
    SpotubeAudioSourceMatchObject sibling,
  ) async {
    return await update((prev) async {
      return await prev.swapWithSibling(sibling) ?? prev;
    });
  }

  Future<SourcedTrack> swapWithNextSibling() async {
    return await update((prev) async {
      return await prev.swapWithSibling(prev.siblings.first) as SourcedTrack;
    });
  }
}

final sourcedTrackProvider = AsyncNotifierProviderFamily<SourcedTrackNotifier,
    SourcedTrack, SpotubeFullTrackObject>(
  () => SourcedTrackNotifier(),
);

import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotube/models/database/database.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/models/playback/track_sources.dart';
import 'package:spotube/provider/database/database.dart';
import 'package:spotube/provider/metadata_plugin/audio_source/quality_presets.dart';
import 'package:spotube/provider/metadata_plugin/metadata_plugin_provider.dart';
import 'package:spotube/services/dio/dio.dart';
import 'package:spotube/services/logger/logger.dart';
import 'package:spotube/services/metadata/errors/exceptions.dart';

import 'package:spotube/services/sourced_track/exceptions.dart';
import 'package:spotube/utils/service_utils.dart';

final officialMusicRegex = RegExp(
  r"official\s(video|audio|music\svideo|lyric\svideo|visualizer)",
  caseSensitive: false,
);

class SourcedTrack extends BasicSourcedTrack {
  final Ref ref;

  SourcedTrack({
    required this.ref,
    required super.info,
    required super.query,
    required super.source,
    required super.siblings,
    required super.sources,
  });

  static Future<SourcedTrack> fetchFromTrack({
    required SpotubeFullTrackObject query,
    required Ref ref,
  }) async {
    final audioSource = await ref.read(audioSourcePluginProvider.future);
    final audioSourceConfig = await ref.read(metadataPluginsProvider
        .selectAsync((data) => data.defaultAudioSourcePluginConfig));
    if (audioSource == null || audioSourceConfig == null) {
      throw MetadataPluginException.noDefaultAudioSourcePlugin();
    }

    final database = ref.read(databaseProvider);
    final cachedSource = await (database.select(database.sourceMatchTable)
          ..where((s) =>
              s.trackId.equals(query.id) &
              s.sourceType.equals(audioSourceConfig.slug))
          ..limit(1)
          ..orderBy([
            (s) =>
                OrderingTerm(expression: s.createdAt, mode: OrderingMode.desc),
          ]))
        .get()
        .then((s) => s.firstOrNull);

    if (cachedSource == null) {
      final siblings = await fetchSiblings(ref: ref, query: query);
      if (siblings.isEmpty) {
        throw TrackNotFoundError(query);
      }

      await database.into(database.sourceMatchTable).insert(
            SourceMatchTableCompanion.insert(
              trackId: query.id,
              sourceInfo: Value(jsonEncode(siblings.first)),
              sourceType: audioSourceConfig.slug,
            ),
          );

      final manifest = await audioSource.audioSource.streams(siblings.first);

      return SourcedTrack(
        ref: ref,
        siblings: siblings.skip(1).toList(),
        info: siblings.first,
        source: audioSourceConfig.slug,
        sources: manifest,
        query: query,
      );
    }
    final item = SpotubeAudioSourceMatchObject.fromJson(
      jsonDecode(cachedSource.sourceInfo),
    );
    final manifest = await audioSource.audioSource.streams(item);

    final sourcedTrack = SourcedTrack(
      ref: ref,
      siblings: [],
      sources: manifest,
      info: item,
      query: query,
      source: audioSourceConfig.slug,
    );

    AppLogger.log.i("${query.name}: ${sourcedTrack.url}");

    return sourcedTrack;
  }

  static List<SpotubeAudioSourceMatchObject> rankResults(
    List<SpotubeAudioSourceMatchObject> results,
    SpotubeFullTrackObject track,
  ) {
    return results
        .map((sibling) {
          int score = 0;

          for (final artist in track.artists) {
            final isSameChannelArtist =
                sibling.artists.any((a) => a.toLowerCase() == artist.name);

            if (isSameChannelArtist) {
              score += 1;
            }

            final titleContainsArtist =
                sibling.title.toLowerCase().contains(artist.name.toLowerCase());

            if (titleContainsArtist) {
              score += 1;
            }
          }

          final titleContainsTrackName =
              sibling.title.toLowerCase().contains(track.name.toLowerCase());

          final hasOfficialFlag =
              officialMusicRegex.hasMatch(sibling.title.toLowerCase());

          if (titleContainsTrackName) {
            score += 3;
          }

          if (hasOfficialFlag) {
            score += 1;
          }

          if (hasOfficialFlag && titleContainsTrackName) {
            score += 2;
          }

          return (sibling: sibling, score: score);
        })
        .sorted((a, b) => b.score.compareTo(a.score))
        .map((e) => e.sibling)
        .toList();
  }

  static Future<List<SpotubeAudioSourceMatchObject>> fetchSiblings({
    required SpotubeFullTrackObject query,
    required Ref ref,
  }) async {
    final audioSource = await ref.read(audioSourcePluginProvider.future);

    if (audioSource == null) {
      throw MetadataPluginException.noDefaultAudioSourcePlugin();
    }

    final videoResults = <SpotubeAudioSourceMatchObject>[];

    final searchResults = await audioSource.audioSource.matches(query);

    if (ServiceUtils.onlyContainsEnglish(query.name)) {
      videoResults.addAll(searchResults);
    } else {
      videoResults.addAll(rankResults(searchResults, query));
    }

    return videoResults.toSet().toList();
  }

  Future<SourcedTrack> copyWithSibling() async {
    if (siblings.isNotEmpty) {
      return this;
    }
    final fetchedSiblings = await fetchSiblings(ref: ref, query: query);

    return SourcedTrack(
      ref: ref,
      siblings: fetchedSiblings.where((s) => s.id != info.id).toList(),
      source: source,
      sources: sources,
      info: info,
      query: query,
    );
  }

  Future<SourcedTrack?> swapWithSibling(
    SpotubeAudioSourceMatchObject sibling,
  ) async {
    if (sibling.id == info.id) {
      return null;
    }

    final audioSource = await ref.read(audioSourcePluginProvider.future);
    final audioSourceConfig = await ref.read(metadataPluginsProvider
        .selectAsync((data) => data.defaultAudioSourcePluginConfig));
    if (audioSource == null || audioSourceConfig == null) {
      throw MetadataPluginException.noDefaultAudioSourcePlugin();
    }

    // a sibling source that was fetched from the search results
    final isStepSibling = siblings.none((s) => s.id == sibling.id);

    final newSourceInfo = isStepSibling
        ? sibling
        : siblings.firstWhere((s) => s.id == sibling.id);

    final newSiblings = siblings.where((s) => s.id != sibling.id).toList()
      ..insert(0, info);

    final manifest = await audioSource.audioSource.streams(newSourceInfo);

    final database = ref.read(databaseProvider);

    // Delete the old Entry
    await (database.sourceMatchTable.delete()
          ..where(
            (table) =>
                table.trackId.equals(query.id) &
                table.sourceType.equals(audioSourceConfig.slug),
          ))
        .go();

    await database.into(database.sourceMatchTable).insert(
          SourceMatchTableCompanion.insert(
            trackId: query.id,
            sourceInfo: Value(jsonEncode(sibling)),
            sourceType: audioSourceConfig.slug,
            createdAt: Value(DateTime.now()),
          ),
          mode: InsertMode.replace,
        );

    return SourcedTrack(
      ref: ref,
      source: source,
      siblings: newSiblings,
      sources: manifest,
      info: newSourceInfo,
      query: query,
    );
  }

  Future<SourcedTrack?> swapWithSiblingOfIndex(int index) {
    return swapWithSibling(siblings[index]);
  }

  Future<SourcedTrack> refreshStream() async {
    final audioSource = await ref.read(audioSourcePluginProvider.future);
    final audioSourceConfig = await ref.read(metadataPluginsProvider
        .selectAsync((data) => data.defaultAudioSourcePluginConfig));
    if (audioSource == null || audioSourceConfig == null) {
      throw MetadataPluginException.noDefaultAudioSourcePlugin();
    }

    List<SpotubeAudioSourceStreamObject> validStreams = [];

    final stringBuffer = StringBuffer();
    for (final source in sources) {
      final res = await globalDio.head(
        source.url,
        options:
            Options(validateStatus: (status) => status != null && status < 500),
      );

      stringBuffer.writeln(
        "[${query.id}] ${res.statusCode} ${source.container} ${source.codec} ${source.bitrate}",
      );

      if (res.statusCode! < 400) {
        validStreams.add(source);
      }
    }

    AppLogger.log.d(stringBuffer.toString());

    if (validStreams.isEmpty) {
      validStreams = await audioSource.audioSource.streams(info);
    }

    final sourcedTrack = SourcedTrack(
      ref: ref,
      siblings: siblings,
      source: source,
      sources: validStreams,
      info: info,
      query: query,
    );

    AppLogger.log.i("Refreshing ${query.name}: ${sourcedTrack.url}");

    return sourcedTrack;
  }

  /// The stream that will actually be played for the current streaming
  /// settings, after any format fallback.
  SpotubeAudioSourceStreamObject? get activeStream {
    final preferences = ref.read(audioSourcePresetsProvider);

    return getStreamOfQuality(
      preferences.presets[preferences.selectedStreamingContainerIndex],
      preferences.selectedStreamingQualityIndex,
    );
  }

  String? get url => activeStream?.url;

  /// Container of the stream actually being played (falls back to the chosen
  /// preset name when no stream is available yet).
  String get activeContainer => activeStream?.container ?? qualityPreset!.name;

  /// File extension matching [activeContainer].
  String get activeFileExtension =>
      activeStream?.fileExtension ?? qualityPreset!.getFileExtension();

  /// Containers tried, in order, when no stream matches the chosen one.
  /// Lossless first, then Opus (webm), then AAC (mp4).
  static const fallbackContainers = ["flac", "webm", "mp4"];

  /// Remembers which fallbacks were already logged for this track so the
  /// `url` getter (called many times per play) logs each one only once.
  final Set<String> _loggedFallbacks = {};

  /// Returns the stream closest to the chosen container and quality.
  ///
  /// If no stream has the chosen container (e.g. FLAC chosen but the song
  /// only exists on YouTube), falls back through [fallbackContainers] and
  /// finally to any container at all, so a song always plays when it has
  /// at least one stream. Returns null only when there are no streams.
  SpotubeAudioSourceStreamObject? getStreamOfQuality(
    SpotubeAudioSourceContainerPreset preset,
    int qualityIndex,
  ) {
    if (sources.isEmpty) return null;

    final quality = preset.qualities[qualityIndex];

    final wanted = sources.where((s) => s.container == preset.name).toList();
    if (wanted.isNotEmpty) {
      return _closestStream(wanted, quality);
    }

    final order = [
      ...fallbackContainers.where((c) => c != preset.name),
      ...sources.map((s) => s.container).toSet()
        ..removeAll(fallbackContainers)
        ..remove(preset.name),
    ];

    for (final container in order) {
      final candidates = sources.where((s) => s.container == container);
      if (candidates.isEmpty) continue;

      final pick = _closestStream(candidates.toList(), quality);
      if (_loggedFallbacks.add(container)) {
        AppLogger.log.i(
          "Format fallback for \"${query.name}\": wanted ${preset.name}, "
          "got ${pick.container} ${pick.codec ?? ""} "
          "${pick.bitrate != null ? "${(pick.bitrate! / 1000).round()}k" : ""}"
              .trim(),
        );
      }
      return pick;
    }

    return null;
  }

  /// Picks the stream closest to [quality] from a non-empty [candidates] list.
  /// Exact match wins. If the quality kind does not match the streams
  /// (lossless wanted, lossy available, or the reverse) the best available
  /// stream is returned.
  static SpotubeAudioSourceStreamObject _closestStream(
    List<SpotubeAudioSourceStreamObject> candidates,
    Object quality,
  ) {
    assert(candidates.isNotEmpty);

    if (quality is SpotubeAudioLosslessContainerQuality) {
      final exact = candidates.firstWhereOrNull((s) =>
          s.sampleRate == quality.sampleRate && s.bitDepth == quality.bitDepth);
      if (exact != null) return exact;

      final lossless = candidates.where((s) => s.sampleRate != null).toList();
      if (lossless.isNotEmpty) {
        return lossless.reduce((prev, curr) {
          final prevDiff =
              ((prev.sampleRate ?? 0) - quality.sampleRate).abs() +
                  ((prev.bitDepth ?? 0) - quality.bitDepth).abs();
          final currDiff =
              ((curr.sampleRate ?? 0) - quality.sampleRate).abs() +
                  ((curr.bitDepth ?? 0) - quality.bitDepth).abs();
          return currDiff < prevDiff ? curr : prev;
        });
      }
      // Lossless wanted but only lossy streams here: take the best bitrate.
      return candidates.reduce(
          (prev, curr) => (curr.bitrate ?? 0) > (prev.bitrate ?? 0) ? curr : prev);
    }

    final lossy = quality as SpotubeAudioLossyContainerQuality;
    final exact = candidates.firstWhereOrNull((s) => s.bitrate == lossy.bitrate);
    if (exact != null) return exact;

    final withBitrate = candidates.where((s) => s.bitrate != null).toList();
    if (withBitrate.isNotEmpty) {
      return withBitrate.reduce((prev, curr) {
        final prevDiff = ((prev.bitrate ?? 0) - lossy.bitrate).abs();
        final currDiff = ((curr.bitrate ?? 0) - lossy.bitrate).abs();
        return currDiff < prevDiff ? curr : prev;
      });
    }
    // Lossy wanted but only lossless (no bitrate) streams here: best one.
    return candidates.reduce((prev, curr) =>
        ((curr.sampleRate ?? 0) + (curr.bitDepth ?? 0)) >
                ((prev.sampleRate ?? 0) + (prev.bitDepth ?? 0))
            ? curr
            : prev);
  }

  String? getUrlOfQuality(
    SpotubeAudioSourceContainerPreset preset,
    int qualityIndex,
  ) {
    return getStreamOfQuality(preset, qualityIndex)?.url;
  }

  SpotubeAudioSourceContainerPreset? get qualityPreset {
    final presetState = ref.read(audioSourcePresetsProvider);
    return presetState.presets
        .elementAtOrNull(presetState.selectedStreamingContainerIndex);
  }
}

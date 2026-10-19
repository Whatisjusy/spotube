import 'dart:async';
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
import 'package:spotube/provider/youtube_engine/youtube_engine.dart';
import 'package:spotube/services/dio/dio.dart';
import 'package:spotube/services/logger/logger.dart';
import 'package:spotube/services/metadata/errors/exceptions.dart';

import 'package:spotube/services/sourced_track/exceptions.dart';
import 'package:spotube/services/sourced_track/source_label.dart'
    as source_label;
import 'package:spotube/services/youtube_engine/youtube_engine.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' show Video;

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
      final (siblings, fromFallback) =
          await _fetchSiblingsDetailed(ref: ref, query: query);
      if (siblings.isEmpty) {
        throw TrackNotFoundError(query);
      }

      final manifest = await streamsWithFallback(
        pluginStreams: () => audioSource.audioSource.streams(siblings.first),
        match: siblings.first,
        query: query,
        engine: ref.read(youtubeEngineProvider),
      );

      // A pick made because the plugin timed out is not saved, so the plugin
      // gets another chance (and lossless can win) on the next play.
      if (!fromFallback) {
        await database.into(database.sourceMatchTable).insert(
              SourceMatchTableCompanion.insert(
                trackId: query.id,
                sourceInfo: Value(jsonEncode(siblings.first)),
                sourceType: audioSourceConfig.slug,
              ),
            );
      }

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
    final manifest = await streamsWithFallback(
      pluginStreams: () => audioSource.audioSource.streams(item),
      match: item,
      query: query,
      engine: ref.read(youtubeEngineProvider),
    );

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

  /// Title words that mark a version the listener did not ask for, unless
  /// the Spotify title itself carries the word.
  static const wrongVersionWords = [
    "live",
    "remix",
    "cover",
    "slowed",
    "sped up",
    "8d",
    "nightcore",
    "reaction",
    "karaoke",
    "instrumental",
  ];

  static const musicVideoWords = source_label.musicVideoWords;

  static const cleanAudioWords = [
    "official audio",
    "audio",
    "lyric",
    "lyrics",
    "visualizer",
    "visualiser",
  ];

  /// Lowercases and strips punctuation so titles compare loosely:
  /// "Jul - C'est La Cité (Audio)" -> "jul cest la cite audio".
  static String normalize(String text) {
    return text
        .toLowerCase()
        .replaceAll(RegExp(r"[^\p{L}\p{N}\s]", unicode: true), "")
        .replaceAll(RegExp(r"\s+"), " ")
        .trim();
  }

  static bool isYouTubeMatch(SpotubeAudioSourceMatchObject m) {
    final uri = m.externalUri.toLowerCase();
    return uri.contains("youtube.com") ||
        uri.contains("youtu.be") ||
        m.id.startsWith("youtube:");
  }

  /// Plugins send the match length as a bare number that the model decodes
  /// as microseconds, but YouTube Audio sends seconds and Monochrome sends
  /// milliseconds. Guess the unit from the size; music is never 10 h long.
  static double matchSeconds(SpotubeAudioSourceMatchObject m) {
    final raw = m.duration.inMicroseconds;
    if (raw <= 0) return 0;
    if (raw < 36000) return raw.toDouble(); // seconds (< 10 h)
    if (raw < 36000 * 1000) return raw / 1000; // milliseconds
    return raw / 1000000; // microseconds
  }

  /// Scores one YouTube result against the Spotify track. Higher is better.
  /// Rewards the label's own upload (" - Topic", "Official Audio", lyric
  /// videos, matching length) and penalises music videos and other versions.
  static int scoreMatch(
    SpotubeAudioSourceMatchObject m,
    SpotubeFullTrackObject track,
  ) {
    final title = normalize(m.title);
    final rawTitle = m.title.toLowerCase();
    final trackName = normalize(track.name);
    final trackNameLower = track.name.toLowerCase();
    final channel = m.artists.firstOrNull ?? "";
    final channelNorm = normalize(channel)
        .replaceAll(RegExp(r"\b(topic|vevo|official)\b"), "")
        .trim();

    var score = 0;

    if (channel.trim().toLowerCase().endsWith("- topic")) score += 6;

    if (cleanAudioWords.any((w) => rawTitle.contains(w))) score += 3;

    if (title.contains(trackName)) score += 3;

    for (final artist in track.artists) {
      final name = normalize(artist.name);
      if (name.isEmpty) continue;
      if (title.contains(name)) score += 1;
      if (channelNorm == name || channelNorm.contains(name)) score += 2;
    }

    if (track.durationMs > 0) {
      final seconds = matchSeconds(m);
      if (seconds > 0) {
        final diff = (seconds - track.durationMs / 1000).abs();
        if (diff <= 2) {
          score += 3;
        } else if (diff <= 5) {
          score += 1;
        } else if (diff > 10) {
          score -= 4;
        }
      }
    }

    if (musicVideoWords.any((w) => rawTitle.contains(w))) score -= 3;

    for (final w in wrongVersionWords) {
      if (rawTitle.contains(w) && !trackNameLower.contains(w)) score -= 5;
    }

    // Plugins that send no channel name: fall back to the old title check.
    if (channel.isEmpty && officialMusicRegex.hasMatch(rawTitle)) score += 1;

    return score;
  }

  /// Orders search results so the cleanest match for [track] comes first.
  ///
  /// Only YouTube results are scored; anything else (Monochrome, hifi-api)
  /// keeps the plugin's order and stays ahead of them. YouTube results whose
  /// title shares nothing with the song name are dropped, unless that would
  /// drop everything, because an ISRC search for an unknown code returns
  /// unrelated videos.
  static List<SpotubeAudioSourceMatchObject> rankResults(
    List<SpotubeAudioSourceMatchObject> results,
    SpotubeFullTrackObject track,
  ) {
    final others = results.where((m) => !isYouTubeMatch(m)).toList();
    final youtube = results.where(isYouTubeMatch).toList();
    if (youtube.isEmpty) return others;

    final trackName = normalize(track.name);
    var plausible = youtube.where((m) {
      final title = normalize(m.title);
      return trackName.isEmpty ||
          title.contains(trackName) ||
          trackName.contains(title);
    }).toList();
    if (plausible.isEmpty) plausible = youtube;

    final scored = plausible
        .mapIndexed((i, m) => (index: i, match: m, score: scoreMatch(m, track)))
        .sorted((a, b) {
      final byScore = b.score.compareTo(a.score);
      return byScore != 0 ? byScore : a.index.compareTo(b.index);
    });

    return [...others, ...scored.map((e) => e.match)];
  }

  /// How long a plugin lookup (matches or streams) may take before the app
  /// finds the song on YouTube by itself so playback still starts.
  static const audioSourceTimeout = Duration(seconds: 4);

  /// Video id of a YouTube match, whichever plugin made it: `youtube:<id>`,
  /// a watch link with `v=`, or a bare 11-character id. Null otherwise.
  static String? youtubeVideoId(SpotubeAudioSourceMatchObject m) {
    if (m.id.startsWith("youtube:")) return m.id.substring("youtube:".length);
    final v = Uri.tryParse(m.externalUri)?.queryParameters["v"];
    if (v != null && v.isNotEmpty) return v;
    if (RegExp(r"^[A-Za-z0-9_-]{11}$").hasMatch(m.id)) return m.id;
    return null;
  }

  /// Search text for a direct YouTube lookup of [track].
  static String youtubeQueryFor(SpotubeFullTrackObject track) {
    return "${track.artists.map((a) => a.name).join(" ")} ${track.name}".trim();
  }

  /// Turns engine search results into the match shape plugins send.
  static List<SpotubeAudioSourceMatchObject> matchesFromVideos(
    List<Video> videos,
  ) {
    return videos
        .map((v) => SpotubeAudioSourceMatchObject(
              id: v.id.value,
              title: v.title,
              artists: [v.author],
              duration: v.duration ?? Duration.zero,
              thumbnail: v.thumbnails.mediumResUrl,
              externalUri: "https://youtube.com/watch?v=${v.id.value}",
            ))
        .toList();
  }

  /// Audio streams for a YouTube video straight from the engine, in the
  /// shape plugins send (lossy mp4 / webm).
  static Future<List<SpotubeAudioSourceStreamObject>> streamsFromEngine(
    YouTubeEngine engine,
    String videoId,
  ) async {
    final manifest = await engine.getStreamManifest(videoId);
    return manifest.audioOnly
        .map((s) => SpotubeAudioSourceStreamObject(
              url: s.url.toString(),
              container: s.container.name,
              type: SpotubeMediaCompressionType.lossy,
              codec: s.audioCodec,
              bitrate: s.bitrate.bitsPerSecond.toDouble(),
            ))
        .toList();
  }

  /// Finds [track] on YouTube without the plugin: songs-first search, then
  /// the clean-audio ranking.
  static Future<List<SpotubeAudioSourceMatchObject>> youtubeFallbackMatches(
    YouTubeEngine engine,
    SpotubeFullTrackObject track,
  ) async {
    final videos = await searchYouTubeCleanFirst(engine, youtubeQueryFor(track));
    return rankResults(matchesFromVideos(videos), track);
  }

  /// Calls the plugin's `streams` with a time limit. If it is too slow, or
  /// fails for a YouTube match, the streams come from the YouTube engine
  /// instead: for a YouTube match, that same video; for anything else (a
  /// Monochrome match while Monochrome is down), the best YouTube result for
  /// the song. The saved match is left alone so lossless can win next time.
  static Future<List<SpotubeAudioSourceStreamObject>> streamsWithFallback({
    required Future<List<SpotubeAudioSourceStreamObject>> Function()
        pluginStreams,
    required SpotubeAudioSourceMatchObject match,
    required SpotubeFullTrackObject query,
    required YouTubeEngine engine,
    Duration timeout = audioSourceTimeout,
  }) async {
    final watch = Stopwatch()..start();
    try {
      final streams = await pluginStreams().timeout(timeout);
      AppLogger.log.d(
        "streams for \"${query.name}\" took ${watch.elapsedMilliseconds} ms",
      );
      return streams;
    } on TimeoutException {
      AppLogger.log.w(
        "Audio source plugin took over ${timeout.inSeconds}s to fetch streams "
        "for \"${query.name}\" (${match.id}); using YouTube directly",
      );
    } catch (e, stack) {
      if (youtubeVideoId(match) == null) rethrow;
      AppLogger.log.w(
        "Audio source plugin failed to fetch streams for \"${query.name}\" "
        "(${match.id}); using the YouTube engine directly: $e",
      );
      AppLogger.reportError(e, stack);
    }

    final videoId = youtubeVideoId(match);
    if (videoId != null) return streamsFromEngine(engine, videoId);

    final fallback = await youtubeFallbackMatches(engine, query);
    if (fallback.isEmpty) throw TrackNotFoundError(query);
    AppLogger.log.i(
      "YouTube stand-in for \"${query.name}\": ${fallback.first.title} "
      "(${fallback.first.artists.join(", ")})",
    );
    return streamsFromEngine(engine, youtubeVideoId(fallback.first)!);
  }

  static Future<List<SpotubeAudioSourceMatchObject>> fetchSiblings({
    required SpotubeFullTrackObject query,
    required Ref ref,
  }) async {
    final (siblings, _) = await _fetchSiblingsDetailed(ref: ref, query: query);
    return siblings;
  }

  /// Like [fetchSiblings]; the flag says the plugin timed out and the list
  /// came from a direct YouTube search instead.
  static Future<(List<SpotubeAudioSourceMatchObject>, bool)>
      _fetchSiblingsDetailed({
    required SpotubeFullTrackObject query,
    required Ref ref,
  }) async {
    final audioSource = await ref.read(audioSourcePluginProvider.future);

    if (audioSource == null) {
      throw MetadataPluginException.noDefaultAudioSourcePlugin();
    }

    List<SpotubeAudioSourceMatchObject> searchResults;
    var fromFallback = false;
    final watch = Stopwatch()..start();
    try {
      searchResults =
          await audioSource.audioSource.matches(query).timeout(audioSourceTimeout);
      AppLogger.log.d(
        "matches for \"${query.name}\" took ${watch.elapsedMilliseconds} ms",
      );
    } on TimeoutException {
      AppLogger.log.w(
        "Audio source plugin took over ${audioSourceTimeout.inSeconds}s to "
        "match \"${query.name}\"; searching YouTube directly",
      );
      searchResults = matchesFromVideos(await searchYouTubeCleanFirst(
        ref.read(youtubeEngineProvider),
        youtubeQueryFor(query),
      ));
      fromFallback = true;
    }

    final ranked = rankResults(searchResults, query).toSet().toList();

    final top = ranked.where(isYouTubeMatch).take(3).toList();
    if (top.isNotEmpty) {
      AppLogger.log.i(
        "Ranked YouTube results for \"${query.name}\": ${top.map((m) => "[${scoreMatch(m, query)}] ${m.title} (${m.artists.join(", ")})").join(" | ")}",
      );
    }

    return (ranked, fromFallback);
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

    final manifest = await streamsWithFallback(
      pluginStreams: () => audioSource.audioSource.streams(newSourceInfo),
      match: newSourceInfo,
      query: query,
      engine: ref.read(youtubeEngineProvider),
    );

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
      validStreams = await streamsWithFallback(
        pluginStreams: () => audioSource.audioSource.streams(info),
        match: info,
        query: query,
        engine: ref.read(youtubeEngineProvider),
      );
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

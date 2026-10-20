import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart' hide Response;
import 'package:dio/dio.dart' as dio_lib;
import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:metadata_god/metadata_god.dart';
import 'package:path/path.dart';
import 'package:shelf/shelf.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/models/parser/range_headers.dart';
import 'package:spotube/provider/audio_player/audio_player.dart';
import 'package:spotube/provider/audio_player/state.dart';

import 'package:spotube/provider/server/sourced_track_provider.dart';
import 'package:spotube/provider/user_preferences/user_preferences_provider.dart';
import 'package:spotube/services/audio_player/audio_player.dart';
import 'package:spotube/services/logger/logger.dart';
import 'package:spotube/services/network_cost.dart';
import 'package:spotube/services/sourced_track/sourced_track.dart';
import 'package:spotube/utils/flac_check.dart';
import 'package:spotube/utils/service_utils.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

final _deviceClients = Set.unmodifiable({
  YoutubeApiClient.ios,
  YoutubeApiClient.android,
  YoutubeApiClient.mweb,
  YoutubeApiClient.safari,
});

String? get _randomUserAgent => _deviceClients
    .elementAt(
      Random().nextInt(_deviceClients.length),
    )
    .payload["context"]["client"]["userAgent"];

class ServerPlaybackRoutes {
  final Ref ref;
  UserPreferences get userPreferences => ref.read(userPreferencesProvider);
  AudioPlayerState get playlist => ref.read(audioPlayerProvider);
  final Dio dio;

  ServerPlaybackRoutes(this.ref) : dio = Dio() {
    unawaited(_sweepStaleTempFiles());
  }

  /// Cache file paths with a background download in flight, and the token
  /// that stops each one.
  final _prefetching = <String, CancelToken>{};

  /// The lookups of the last few tracks started, so their seeks are served
  /// from the same stream.
  final _playing = <String, SourcedTrack>{};

  /// The song the engine most recently asked for from byte 0, noted when the
  /// request arrives (before its lookup), so a slower earlier request cannot
  /// mark its song as playing after the listener has skipped past it.
  String? _latestStartRequest;
  Future<void>? _staleTempSweep;

  /// Removes ".part" / ".prefetch" files left by a previous run that was
  /// quit mid-download. Nothing survives a restart, so they are all stale,
  /// and a stale ".part" would otherwise block caching that track for good.
  /// Runs once; later callers wait for that same run, so a new ".part" is
  /// never created while the sweep could still delete it.
  Future<void> _sweepStaleTempFiles() =>
      _staleTempSweep ??= _deleteStaleTempFiles();

  Future<void> _deleteStaleTempFiles() async {
    try {
      final dir = Directory(await UserPreferencesNotifier.getMusicCacheDir());
      if (!await dir.exists()) return;
      await for (final entity in dir.list()) {
        if (entity is File &&
            (entity.path.endsWith(".part") ||
                entity.path.endsWith(".prefetch"))) {
          await entity.delete();
        }
      }
    } catch (e, stack) {
      AppLogger.reportError(e, stack);
    }
  }

  /// Downloads [track]'s audio into the music cache ahead of time so the
  /// engine can start it straight from disk. Does nothing when caching is
  /// off, the file is already cached, or a download is already running.
  Future<void> prefetchToCache(SourcedTrack track) async {
    if (!userPreferences.cacheMusic) return;
    // Whole-song downloads ahead cost too much on mobile data.
    if (NetworkCost.onMobileData) return;
    final url = track.url;
    if (url == null) return;

    await _sweepStaleTempFiles();
    final cacheFile = File(await _getTrackCacheFilePath(track));
    if (await cacheFile.exists() || _prefetching.containsKey(cacheFile.path)) {
      return;
    }
    final cancel = CancelToken();
    _prefetching[cacheFile.path] = cancel;

    // Separate temp file: the live stream path writes its own ".part", and
    // both may run at once if the listener skips ahead mid-download.
    final tempFile = File("${cacheFile.path}.prefetch");
    try {
      final res = await dio.get<ResponseBody>(
        url,
        cancelToken: cancel,
        options: Options(
          headers: {
            "user-agent": _randomUserAgent,
            "host": Uri.parse(url).host,
          },
          responseType: ResponseType.stream,
          validateStatus: (status) => status! < 400,
        ),
      );
      // HLS playlists can't be cached as one file.
      if (res.headers.value("content-type") ==
          "application/vnd.apple.mpegurl") {
        return;
      }
      final total = int.tryParse(res.headers.value("content-length") ?? "");

      await tempFile.create(recursive: true);
      final sink = tempFile.openWrite();
      await sink.addStream(res.data!.stream);
      await sink.close();

      final length = await tempFile.length();
      if (total != null && length != total) {
        await tempFile.delete();
        return;
      }
      await tempFile.rename(cacheFile.path);
      AppLogger.log.i(
        'Prefetched "${track.query.name}" to cache (${length ~/ 1024} KB)',
      );
      await _tagCacheFile(track, cacheFile, length);
    } catch (e, stack) {
      if (cancel.isCancelled) {
        AppLogger.log.i('Prefetch of "${track.query.name}" cancelled');
      } else {
        AppLogger.reportError(e, stack);
      }
      if (await tempFile.exists()) await tempFile.delete();
    } finally {
      _prefetching.remove(cacheFile.path);
    }
  }

  Future<void> _tagCacheFile(
    SourcedTrack track,
    File cacheFile,
    int fileLength,
  ) async {
    if (track.activeFileExtension == "weba") return;
    // Writing tags into a FLAC without padding has left the metadata pointing
    // a few KB off the first audio frame (12 of 45 cached FLACs on the Mac).
    if (cacheFile.path.endsWith(".flac")) return;

    final imageBytes = await ServiceUtils.downloadImage(
      track.query.album.images.asUrlString(
        placeholder: ImagePlaceholder.albumArt,
        index: 1,
      ),
    );

    await MetadataGod.writeMetadata(
      file: cacheFile.path,
      metadata: track.query.toMetadata(
        imageBytes: imageBytes,
        fileLength: fileLength,
      ),
    ).catchError((e, stackTrace) {
      AppLogger.reportError(e, stackTrace);
    });
  }

  Future<String> _getTrackCacheFilePath(
    SourcedTrack track, {
    String? extension,
  }) async {
    return join(
      await UserPreferencesNotifier.getMusicCacheDir(),
      ServiceUtils.sanitizeFilename(
        '${track.query.name} - ${track.query.artists.map((d) => d.name).join(",")} (${track.info.id}).${extension ?? track.activeFileExtension}',
      ),
    );
  }

  /// The complete cached file for [track], or null when there is none or
  /// caching is off. A FLAC or full-quality copy (saved on Wi-Fi) wins even
  /// on mobile data: it is better and costs nothing to play.
  Future<File?> _cachedFileFor(SourcedTrack track) async {
    if (!userPreferences.cacheMusic) return null;
    final extensions = {
      "flac",
      if (track.fullQualityStream case final stream?) stream.fileExtension,
      track.activeFileExtension,
    };
    for (final extension in extensions) {
      final file = File(
        await _getTrackCacheFilePath(track, extension: extension),
      );
      if (await _usableCacheFile(file, track)) return file;
    }
    return null;
  }

  /// Exists, is not empty and is not a damaged FLAC. A bad one is deleted so
  /// the track streams live and gets cached again. (An empty file used to
  /// fail every request for that track: no bytes to serve, and a range
  /// request crashed the handler.)
  Future<bool> _usableCacheFile(File file, SourcedTrack track) async {
    if (!await file.exists()) return false;
    final empty = await file.length() == 0;
    if (!empty &&
        (!file.path.endsWith(".flac") || await flacLooksPlayable(file))) {
      return true;
    }
    AppLogger.log.w(
      "Deleted ${empty ? "empty" : "damaged"} cached file for "
      "\"${track.query.name}\"; streaming it",
    );
    await file.delete().catchError((_) => file);
    return false;
  }

  /// Serves a cached file the way a real HTTP server would: byte ranges are
  /// honoured with 206 responses. The engine seeks by asking for ranges; if
  /// it gets the whole file from byte 0 instead, the decoder reads misaligned
  /// data ("flac: invalid sync code") and the listener hears a burst of
  /// static. HEAD requests get the headers only.
  Future<Response> _serveCachedFile(
    Request request,
    File file,
    SourcedTrack track,
  ) async {
    final length = await file.length();
    final fileContainer = switch (extension(file.path)) {
      ".m4a" => "mp4",
      ".weba" => "webm",
      final ext => ext.replaceFirst(".", ""),
    };
    final baseHeaders = {
      "content-type": "audio/$fileContainer",
      "accept-ranges": "bytes",
    };
    final isHead = request.method == "HEAD";

    RangeHeader? range;
    final rangeValue = request.headers["range"];
    if (rangeValue != null && rangeValue.isNotEmpty) {
      try {
        range = RangeHeader.parse(rangeValue);
      } on FormatException {
        range = null;
      }
    }

    if (range == null) {
      return Response.ok(
        isHead ? null : file.openRead(),
        headers: {...baseHeaders, "content-length": "$length"},
      );
    }

    final start = range.start;
    final end = (range.end ?? length - 1).clamp(0, length - 1);
    if (start < 0 || start > end || start >= length) {
      return Response(
        416,
        headers: {...baseHeaders, "content-range": "bytes */$length"},
      );
    }
    return Response(
      206,
      body: isHead ? null : file.openRead(start, end + 1),
      headers: {
        ...baseHeaders,
        "content-length": "${end - start + 1}",
        "content-range": "bytes $start-$end/$length",
      },
    );
  }

  Future<SourcedTrack?> _getSourcedTrack(
    Request request,
    String trackId,
  ) async {
    final track =
        playlist.tracks.firstWhere((element) => element.id == trackId);

    final media = audioPlayer.playlist.medias
        .firstWhere((e) => e.uri == request.requestedUri.toString());
    final spotubeMedia =
        media is SpotubeMedia ? media : SpotubeMedia.media(media);
    final query = spotubeMedia.track as SpotubeFullTrackObject;

    // Read the song's own lookup (activeTrackSourcesProvider holds the same
    // one for the playing song, but fails for every song while the playing
    // song's lookup is failed), and look it up again if it had failed.
    return retryFailedRead(
      read: () => ref.read(sourcedTrackProvider(query).future),
      invalidate: () => ref.invalidate(sourcedTrackProvider(query)),
      name: track.name,
    );
  }

  Future<dio_lib.Response> streamTrackInformation(
    Request request,
    SourcedTrack track,
  ) async {
    AppLogger.log.i(
      "HEAD request for track: ${track.query.name}\n"
      "Headers: ${request.headers}",
    );

    String url = track.url ??
        await ref
            .read(sourcedTrackProvider(track.query).notifier)
            .swapWithNextSibling()
            .then((track) => track.url!);

    final options = Options(
      headers: {
        "user-agent": _randomUserAgent,
        "Cache-Control": "max-age=3600",
        "Connection": "keep-alive",
        "host": Uri.parse(url).host,
      },
      validateStatus: (status) => status! < 400,
    );

    final res = await dio.head(url, options: options);

    return res;
  }

  Future<dio_lib.Response> streamTrack(
    Request request,
    SourcedTrack track,
    Map<String, dynamic> headers,
  ) async {
    AppLogger.log.i(
      "GET request for track: ${track.query.name}\n"
      "Headers: ${request.headers}",
    );

    final trackCacheFile = File(await _getTrackCacheFilePath(track));

    String url = track.url ??
        await ref
            .read(sourcedTrackProvider(track.query).notifier)
            .swapWithNextSibling()
            .then((track) => track.url!);

    final options = Options(
      headers: {
        ...headers,
        "user-agent": _randomUserAgent,
        "Cache-Control": "max-age=3600",
        "Connection": "keep-alive",
        "host": Uri.parse(url).host,
      },
      responseType: ResponseType.stream,
      validateStatus: (status) => status! < 400,
    );

    final contentLengthRes = await Future<dio_lib.Response?>.value(
      dio.head(
        url,
        options: options.copyWith(responseType: ResponseType.bytes),
      ),
    ).catchError((e, stack) async {
      AppLogger.reportError(e, stack);

      final sourcedTrack = await ref
          .read(sourcedTrackProvider(track.query).notifier)
          .refreshStreamingUrl();

      url = sourcedTrack.url!;

      return dio.head(url, options: options);
    });

    // Redirect to m3u8 link directly as it handles range requests internally
    if (contentLengthRes?.headers.value("content-type") ==
        "application/vnd.apple.mpegurl") {
      return dio_lib.Response<Uint8List>(
        statusCode: 301,
        statusMessage: "M3U8 Redirect",
        headers: Headers.fromMap({
          "location": [url],
          "content-type": ["application/vnd.apple.mpegurl"],
        }),
        requestOptions: RequestOptions(path: request.requestedUri.toString()),
        isRedirect: true,
      );
    }

    final res = await dio.get<ResponseBody>(url, options: options);

    AppLogger.log.i(
      "Response for track: ${track.query.name}\n"
      "Status Code: ${res.statusCode}\n"
      "Headers: ${res.headers.map}",
    );

    if (!userPreferences.cacheMusic) {
      return res;
    }

    // The listener skipped onto a track still being prefetched: stop that
    // download so the live stream has the whole connection.
    _prefetching[trackCacheFile.path]?.cancel("now streaming live");

    await _sweepStaleTempFiles();
    final contentRange = res.headers.value("content-range") != null
        ? ContentRangeHeader.parse(res.headers.value("content-range") ?? "")
        : ContentRangeHeader(0, 0, 0);
    final trackPartialCacheFile = File("${trackCacheFile.path}.part");

    // Only one writer per track, and only a whole-file response. The engine
    // often opens the same track twice at once; two appenders on one ".part"
    // used to leave a renamed cache file with the slower stream's tail glued
    // on, plus an orphaned ".part". A seek (range) request must not write
    // either, and a background prefetch already in flight will produce it.
    if (contentRange.start != 0 ||
        await trackPartialCacheFile.exists() ||
        _prefetching.containsKey(trackCacheFile.path)) {
      return res;
    }
    await trackPartialCacheFile.create(recursive: true);

    final resStream = res.data!.stream.asBroadcastStream();
    final partialCacheFileSink = trackPartialCacheFile.openWrite();

    Future<void> discard() async {
      await partialCacheFileSink.close().catchError((_) {});
      if (await trackPartialCacheFile.exists()) {
        await trackPartialCacheFile.delete();
      }
    }

    resStream.listen(
      (data) {
        partialCacheFileSink.add(data);
      },
      onError: (e, stack) => discard(),
      onDone: () async {
        try {
          await partialCacheFileSink.close();
          final fileLength = await trackPartialCacheFile.length();
          if (fileLength != contentRange.total) {
            await discard();
            return;
          }
          await trackPartialCacheFile.rename(trackCacheFile.path);
          await _tagCacheFile(track, trackCacheFile, fileLength);
        } catch (e, stack) {
          AppLogger.reportError(e, stack);
          await discard();
        }
      },
      cancelOnError: true,
    );

    res.data?.stream =
        resStream; // To avoid Stream has been already listened to exception
    return res;
  }

  /// @head('/stream/<trackId>')
  Future<Response> headStreamTrackId(Request request, String trackId) async {
    try {
      final sourcedTrack = await _getSourcedTrack(request, trackId);

      if (sourcedTrack == null) {
        return Response.notFound("Track not found in the current queue");
      }

      final cached = await _cachedFileFor(sourcedTrack);
      if (cached != null) {
        return _serveCachedFile(request, cached, sourcedTrack);
      }

      final res = await streamTrackInformation(
        request,
        sourcedTrack,
      );

      return Response(
        res.statusCode!,
        headers: res.headers.map,
      );
    } catch (e, stack) {
      AppLogger.reportError(e, stack);
      return Response.internalServerError();
    }
  }

  /// @get('/stream/<trackId>')
  Future<Response> getStreamTrackId(Request request, String trackId) async {
    try {
      // A request from byte 0 starts the track afresh: pick the stream for
      // the network we are on now. A seek keeps the exact lookup (and
      // stream) that started playing, even if a Wi-Fi/mobile change has
      // since rebuilt it.
      final range = request.headers["range"];
      final freshStart = range == null || range.startsWith("bytes=0-");
      if (freshStart) _latestStartRequest = trackId;
      final sourcedTrack = (freshStart ? null : _playing[trackId]) ??
          await _getSourcedTrack(request, trackId);

      if (sourcedTrack == null) {
        return Response.notFound("Track not found in the current queue");
      }

      if (freshStart) {
        sourcedTrack.pickStreamForNewPlay();
        _playing.remove(trackId);
        _playing[trackId] = sourcedTrack;
        if (_playing.length > 6) _playing.remove(_playing.keys.first);
      }

      // The engine only fetches a track when it starts playing it, so this is
      // the ground truth for "what's playing" even if its index event is late.
      // Unless the listener skipped on while this request waited for its
      // lookup: then a newer song has started and this one must not be shown
      // as playing again.
      if (_latestStartRequest == trackId) {
        ref.read(audioPlayerProvider.notifier).markTrackAsActive(trackId);
      }

      final cached = await _cachedFileFor(sourcedTrack);
      if (cached != null) {
        AppLogger.log.i(
          "Serving \"${sourcedTrack.query.name}\" from cache "
          "(${request.headers["range"] ?? "whole file"})",
        );
        return _serveCachedFile(request, cached, sourcedTrack);
      }

      final res = await streamTrack(
        request,
        sourcedTrack,
        request.headers,
      );

      if (res.data is ResponseBody) {
        return Response(
          res.statusCode!,
          body: (res.data as ResponseBody).stream,
          headers: res.headers.map,
        );
      }

      return Response(
        res.statusCode!,
        body: res.data,
        headers: res.headers.map,
      );
    } catch (e, stack) {
      AppLogger.reportError(e, stack);
      return Response.internalServerError();
    }
  }

  /// @get('/playback/toggle-playback')
  Future<Response> togglePlayback(Request request) async {
    audioPlayer.isPlaying
        ? await audioPlayer.pause()
        : await audioPlayer.resume();

    return Response.ok("Playback toggled");
  }

  /// @get('/playback/previous')
  Future<Response> previousTrack(Request request) async {
    await audioPlayer.skipToPrevious();
    return Response.ok("Previous track");
  }

  /// @get('/playback/next')
  Future<Response> nextTrack(Request request) async {
    await audioPlayer.skipToNext();
    return Response.ok("Next track");
  }
}

final serverPlaybackRoutesProvider =
    Provider((ref) => ServerPlaybackRoutes(ref));

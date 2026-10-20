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

import 'package:spotube/provider/server/active_track_sources.dart';
import 'package:spotube/provider/server/sourced_track_provider.dart';
import 'package:spotube/provider/user_preferences/user_preferences_provider.dart';
import 'package:spotube/services/audio_player/audio_player.dart';
import 'package:spotube/services/logger/logger.dart';
import 'package:spotube/services/sourced_track/sourced_track.dart';
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
  bool _sweptStaleTempFiles = false;

  /// Removes ".part" / ".prefetch" files left by a previous run that was
  /// quit mid-download. Nothing survives a restart, so they are all stale,
  /// and a stale ".part" would otherwise block caching that track for good.
  Future<void> _sweepStaleTempFiles() async {
    if (_sweptStaleTempFiles) return;
    _sweptStaleTempFiles = true;
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

  Future<String> _getTrackCacheFilePath(SourcedTrack track) async {
    return join(
      await UserPreferencesNotifier.getMusicCacheDir(),
      ServiceUtils.sanitizeFilename(
        '${track.query.name} - ${track.query.artists.map((d) => d.name).join(",")} (${track.info.id}).${track.activeFileExtension}',
      ),
    );
  }

  /// The complete cached file for [track], or null when there is none or
  /// caching is off.
  Future<File?> _cachedFileFor(SourcedTrack track) async {
    if (!userPreferences.cacheMusic) return null;
    final file = File(await _getTrackCacheFilePath(track));
    return await file.exists() ? file : null;
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
    final baseHeaders = {
      "content-type": "audio/${track.activeContainer}",
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

    final activeSourcedTrack =
        await ref.read(activeTrackSourcesProvider.future);

    final media = audioPlayer.playlist.medias
        .firstWhere((e) => e.uri == request.requestedUri.toString());
    final spotubeMedia =
        media is SpotubeMedia ? media : SpotubeMedia.media(media);
    final sourcedTrack = activeSourcedTrack?.track.id == track.id
        ? activeSourcedTrack?.source
        : await ref.read(
            sourcedTrackProvider(spotubeMedia.track as SpotubeFullTrackObject)
                .future,
          );

    return sourcedTrack;
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
      final sourcedTrack = await _getSourcedTrack(request, trackId);

      if (sourcedTrack == null) {
        return Response.notFound("Track not found in the current queue");
      }

      // The engine only fetches a track when it starts playing it, so this is
      // the ground truth for "what's playing" even if its index event is late.
      ref.read(audioPlayerProvider.notifier).markTrackAsActive(trackId);

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

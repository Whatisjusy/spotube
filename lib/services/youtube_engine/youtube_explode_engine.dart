import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:spotube/services/logger/logger.dart';
import 'package:spotube/services/youtube_engine/youtube_engine.dart';
import 'package:spotube/services/youtube_engine/youtube_probe.dart';
// import 'package:youtube_explode_dart/solvers.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import 'dart:async';

/// yt-dlp's `visionos` client (2026.08.19, REQUIRE_JS_PLAYER: False).
///
/// Tested 2026-10-20: the android/ios clients this engine used get stream URLs
/// that YouTube serves only up to ~1 MB (HTTP 403 past it, any range size);
/// every other built-in client is refused ("Sign in to confirm you're not a
/// bot"). This one serves whole files, but only after the watch page has
/// been loaded (visitor ID and cookies); without it, it is refused too.
const visionOsClient = YoutubeApiClient({
  'context': {
    'client': {
      'clientName': 'VISIONOS',
      'clientVersion': '1.02',
      'deviceMake': 'Apple',
      'deviceModel': 'RealityDevice17,1',
      'userAgent':
          'Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 '
              '(KHTML, like Gecko) Version/26.0 Safari/605.1.15',
      'osName': 'visionOS',
      'osVersion': '26.5.23O471',
      'hl': 'en',
      'timeZone': 'UTC',
      'utcOffsetMinutes': 0,
    },
  },
}, 'https://www.youtube.com/youtubei/v1/player?prettyPrint=false', headers: {
  'X-YouTube-Client-Name': '101',
  'X-YouTube-Client-Version': '1.02',
  'Sec-Fetch-Mode': 'navigate',
  'Content-Type': 'application/json',
  'Origin': 'https://www.youtube.com',
});

/// Search results as [Video]s, the way `SearchClient.search` builds them but
/// without the upload date (unreadable for "Streamed 3w ago").
List<Video> videosFromSearch(Iterable<SearchResult> results) =>
    results.whereType<SearchVideo>().map((e) {
      return Video(
        e.id,
        e.title,
        e.author,
        ChannelId(e.channelId),
        null,
        e.uploadDate,
        null,
        e.description,
        parseSearchDuration(e.duration),
        ThumbnailSet(e.id.value),
        null,
        Engagement(e.viewCount, null, null),
        e.isLive,
      );
    }).toList();

/// "3:45" or "1:02:03" as a [Duration]; null when absent or unreadable.
Duration? parseSearchDuration(String? text) {
  if (text == null || text.trim().isEmpty) return null;
  final parts = text.trim().split(":").map(int.tryParse).toList();
  if (parts.isEmpty || parts.any((p) => p == null)) return null;
  var seconds = 0;
  for (final p in parts) {
    seconds = seconds * 60 + p!;
  }
  return Duration(seconds: seconds);
}

class _IsolateReply {
  final Object? value;
  final Object? error;
  final String? stack;

  _IsolateReply.ok(this.value)
      : error = null,
        stack = null;
  _IsolateReply.error(Object this.error, this.stack) : value = null;
}

/// It contains methods that are computationally expensive
class IsolatedYoutubeExplode {
  final Isolate _isolate;
  final SendPort _sendPort;
  final ReceivePort _receivePort;

  IsolatedYoutubeExplode._(
    Isolate isolate,
    ReceivePort receivePort,
    SendPort sendPort,
  )   : _isolate = isolate,
        _receivePort = receivePort,
        _sendPort = sendPort;

  static IsolatedYoutubeExplode? _instance;

  static IsolatedYoutubeExplode get instance => _instance!;

  static bool get isInitialized => _instance != null;

  static Future<void> initialize() async {
    if (_instance != null) {
      return;
    }

    final completer = Completer<SendPort>();

    final receivePort = ReceivePort();

    /// Listen for the main isolate to set the main port
    final subscription = receivePort.listen((message) {
      if (message is SendPort) {
        completer.complete(message);
      }
    });

    final isolate = await Isolate.spawn(_isolateEntry, receivePort.sendPort);

    _instance = IsolatedYoutubeExplode._(
      isolate,
      receivePort,
      await completer.future,
    );

    if (completer.isCompleted) {
      subscription.cancel();
    }
  }

  static Future<void> _isolateEntry(SendPort mainSendPort) async {
    final receivePort = ReceivePort();
    // final solver = await DenoEJSSolver.init();
    var youtubeExplode = YoutubeExplode();
    final stopWatch = kDebugMode ? Stopwatch() : null;

    /// Send the main port to the main isolate
    mainSendPort.send(receivePort.sendPort);

    receivePort.listen((message) async {
      final SendPort replyPort = message[0];
      final String methodName = message[1];
      final List<dynamic> arguments = message[2];

      if (stopWatch != null) {
        if (stopWatch.isRunning) {
          stopWatch.stop();
          final symbol = stopWatch.elapsedMilliseconds < 1000 ? "⚠️" : "⏱️";
          debugPrint(
            "$symbol YoutubeExplode operation gap ${stopWatch.elapsedMilliseconds} ms",
          );
          stopWatch.reset();
        } else {
          stopWatch.start();
        }
      }

      // Run the requested method on YoutubeExplode
      var result = switch (methodName) {
        // Not search.search(): it parses every result's upload date and one
        // "Streamed 3w ago" (YouTube's short units) throws for the whole
        // search. searchContent returns the raw results instead.
        "search" => youtubeExplode.search
            .searchContent(
              arguments[0] as String,
              filter: arguments.elementAtOrNull(1) ?? TypeFilters.video,
            )
            .then(videosFromSearch),
        "video" => youtubeExplode.videos.get(arguments[0] as String),
        "manifest" => youtubeExplode.videos.streamsClient.getManifest(
            arguments[0] as String,
            requireWatchPage: arguments.elementAtOrNull(1) ?? true,
            ytClients: arguments.elementAtOrNull(2) as List<YoutubeApiClient>?,
          ),
        // New client = new connections. The old one is closed later so
        // calls still running on it can finish.
        "reset" => Future(() {
            final old = youtubeExplode;
            youtubeExplode = YoutubeExplode();
            Future.delayed(const Duration(seconds: 30), old.close);
            return true;
          }),
        _ => throw ArgumentError('Invalid method name: $methodName'),
      };

      // An uncaught error here used to kill the isolate silently, after which
      // every later call waited forever. Send it back instead.
      try {
        replyPort.send(_IsolateReply.ok(await result));
      } catch (e, stack) {
        try {
          replyPort.send(_IsolateReply.error(e, stack.toString()));
        } catch (_) {
          // The error object itself could not cross the isolate boundary.
          replyPort.send(_IsolateReply.error(Exception("$e"), "$stack"));
        }
      }
    });
  }

  Future<T> _runMethod<T>(String methodName, List<dynamic> args) {
    final completer = Completer<T>();
    final responsePort = ReceivePort();

    responsePort.listen((message) {
      final reply = message as _IsolateReply;
      if (reply.error != null) {
        completer.completeError(
          reply.error!,
          StackTrace.fromString(reply.stack ?? ""),
        );
      } else {
        completer.complete(reply.value as T);
      }
      responsePort.close();
    });

    _sendPort.send([responsePort.sendPort, methodName, args]);
    return completer.future;
  }

  Future<List<Video>> search(
    String query, {
    SearchFilter? filter,
  }) async {
    return _runMethod<List<Video>>("search", [query]);
  }

  Future<Video> video(String videoId) async {
    return _runMethod<Video>("video", [videoId]);
  }

  /// Drops the worker's YouTube session and opens a new one.
  Future<void> resetSession() => _runMethod<bool>("reset", []);

  Future<StreamManifest> manifest(
    String videoId, {
    bool requireWatchPage = false,
    List<YoutubeApiClient>? ytClients,
  }) async {
    return _runMethod<StreamManifest>("manifest", [
      videoId,
      requireWatchPage,
      ytClients,
    ]);
  }

  void dispose() {
    _receivePort.close();
    _isolate.kill(priority: Isolate.immediate);
  }
}

class YouTubeExplodeEngine implements YouTubeEngine {
  static final _youtubeExplode = IsolatedYoutubeExplode.instance;

  static bool get isAvailableForPlatform => true;

  static Future<bool> isInstalled() async {
    return true;
  }

  @override
  Future<StreamManifest> getStreamManifest(String videoId) async {
    await IsolatedYoutubeExplode.initialize();

    StreamManifest streamManifest;
    try {
      streamManifest = await _youtubeExplode.manifest(
        videoId,
        requireWatchPage: true,
        ytClients: [visionOsClient],
      );
      if (streamManifest.audioOnly.isEmpty) {
        throw StateError("visionOS client returned no audio streams");
      }
    } catch (e) {
      AppLogger.log.w(
        "YouTube visionOS client failed for $videoId, using the old clients "
        "(these only serve the first ~1 MB): $e",
      );
      streamManifest = await _youtubeExplode.manifest(
        videoId,
        requireWatchPage: false,
        ytClients: [
          YoutubeApiClient.ios,
          YoutubeApiClient.androidVr,
          YoutubeApiClient.android,
        ],
      );
    }

    final audioStreams = streamManifest.audioOnly.where(
      (stream) => stream.bitrate.bitsPerSecond >= 40960,
    );

    return StreamManifest(
      audioStreams.map(
        (stream) => AudioOnlyStreamInfo(
          stream.videoId,
          stream.tag,
          stream.url,
          stream.container,
          stream.size,
          stream.bitrate,
          stream.audioCodec,
          switch (stream.bitrate.bitsPerSecond) {
            > 130 * 1024 => "high",
            > 64 * 1024 => "medium",
            _ => "low",
          },
          stream.fragments,
          stream.codec,
          stream.audioTrack,
        ),
      ),
    );
  }

  @override
  Future<Video> getVideo(String videoId) async {
    await IsolatedYoutubeExplode.initialize();
    return _youtubeExplode.video(videoId);
  }

  @override
  Future<(Video, StreamManifest)> getVideoWithStreamInfo(String videoId) async {
    await IsolatedYoutubeExplode.initialize();

    final video = await getVideo(videoId);
    final streamManifest = await getStreamManifest(videoId);

    return (video, streamManifest);
  }

  @override
  Future<List<Video>> searchSongs(String query) async {
    // youtube_explode has no YouTube Music "Songs" tab. Returning the video
    // search here made searchYouTubeCleanFirst send the identical request
    // twice at once for every song, doubling what Google sees.
    return const [];
  }

  @override
  Future<List<Video>> searchVideos(String query) async {
    await IsolatedYoutubeExplode.initialize();

    Future<List<Video>> search() => _youtubeExplode
        .search(query, filter: TypeFilters.video)
        .then((searchList) => searchList.toList());

    try {
      return await search();
    } catch (e) {
      // "Failed to retrieve initial data from SearchPage": YouTube sent a
      // page without results now and then (phone, 2026-10-20); the same
      // search a moment later works.
      if ("$e".contains("TransientFailureException")) {
        AppLogger.log.w("YouTube search for \"$query\" came back empty; "
            "trying once more");
        await Future.delayed(const Duration(milliseconds: 700));
        return search();
      }
      if (!isRobotCheck(e)) rethrow;
      _probeAfterBlock();
      // Tested on the phone 2026-10-20: once Google sends this session's
      // searches to its robot check, every later search on it fails too
      // (so every song fails and the player skips through the queue), while
      // the same search on new connections works. Same as an app restart.
      await _resetAfterBlock();
      try {
        final results = await search();
        AppLogger.log.i("YouTube search for \"$query\" worked on a new "
            "session after the robot check");
        return results;
      } catch (e2) {
        AppLogger.log.w("YouTube search for \"$query\" still blocked on a "
            "new session: $e2");
        rethrow;
      }
    }
  }

  /// Both ways Google refused a search on the phone (2026-10-20): a redirect
  /// loop through `google_abuse` (15:55), and a 429 / google.com/sorry that
  /// the library reports as RequestLimitExceededException (16:01). Matched by
  /// text because the error may arrive from the isolate as a plain Exception.
  static bool isRobotCheck(Object error) {
    final text = "$error";
    return text.contains("google_abuse") ||
        text.contains("google.com/sorry") ||
        text.contains("RequestLimitExceededException");
  }

  static DateTime? _lastReset;
  static Future<void>? _resetting;

  /// One new session per block: searches that were already running when it
  /// happened retry on the session made for the first one.
  static Future<void> _resetAfterBlock() {
    final now = DateTime.now();
    if (_resetting != null &&
        _lastReset != null &&
        now.difference(_lastReset!) < const Duration(seconds: 10)) {
      return _resetting!;
    }
    _lastReset = now;
    AppLogger.log.w("YouTube session sent to robot check; starting a new one");
    return _resetting = _youtubeExplode.resetSession();
  }

  static DateTime? _lastBlockProbe;

  /// Diagnostic (2026-10-20): when Google sends a search to its robot check,
  /// ask every endpoint again with fresh connections. If they pass, only this
  /// engine's session is stuck; if they fail too, the network is blocked.
  static void _probeAfterBlock() {
    final now = DateTime.now();
    if (_lastBlockProbe != null &&
        now.difference(_lastBlockProbe!) < const Duration(minutes: 3)) {
      return;
    }
    _lastBlockProbe = now;
    AppLogger.log.w("YouTube search sent to robot check; probing with fresh "
        "connections");
    probeYouTube().then((lines) {
      for (final line in lines) {
        AppLogger.log.w("YouTube probe [after block] $line");
      }
    }).catchError((Object e) {
      AppLogger.log.w("YouTube probe crashed: $e");
    });
  }

  @override
  void dispose() {
    IsolatedYoutubeExplode.instance.dispose();
  }
}

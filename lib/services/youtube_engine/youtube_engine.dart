import 'package:spotube/services/logger/logger.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

abstract interface class YouTubeEngine {
  static bool get isAvailableForPlatform => false;

  static Future<bool> isInstalled() async {
    return false;
  }

  Future<Video> getVideo(String videoId);
  Future<StreamManifest> getStreamManifest(String videoId);
  Future<(Video, StreamManifest)> getVideoWithStreamInfo(String videoId);
  Future<List<Video>> searchVideos(String query);

  /// Searches the YouTube Music "Songs" tab: label uploads only, no music
  /// videos. Engines without that tab fall back to [searchVideos].
  Future<List<Video>> searchSongs(String query);

  void dispose();
}

/// Searches YouTube Music "Songs" and plain YouTube at the same time and
/// returns songs first (label uploads, no music videos), then any videos not
/// already in the list. Plugins keep calling the same `search` and get clean
/// audio first without changing. Either search failing is not fatal.
Future<List<Video>> searchYouTubeCleanFirst(
  YouTubeEngine engine,
  String query,
) async {
  final results = await Future.wait([
    engine.searchSongs(query).catchError((e, stack) {
      AppLogger.reportError(e, stack);
      return <Video>[];
    }),
    engine.searchVideos(query).catchError((e, stack) {
      AppLogger.reportError(e, stack);
      return <Video>[];
    }),
  ]);
  final songs = results[0];
  final videos = results[1];

  final seen = <String>{};
  final merged = [
    for (final v in [...songs, ...videos])
      if (seen.add(v.id.value)) v,
  ];

  AppLogger.log.i(
    "YouTube search \"$query\": ${songs.length} songs, ${videos.length} videos; "
    "top: ${merged.take(3).map((v) => "${v.title} (${v.author})").join(" | ")}",
  );

  return merged;
}

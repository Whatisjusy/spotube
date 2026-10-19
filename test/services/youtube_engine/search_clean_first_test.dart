import 'package:flutter_test/flutter_test.dart';
import 'package:spotube/services/logger/logger.dart';
import 'package:spotube/services/youtube_engine/youtube_engine.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

Video video(String id, String title, String author) {
  return Video(
    VideoId(id),
    title,
    author,
    ChannelId("UC_____________________$id".substring(0, 24)),
    null,
    null,
    null,
    "",
    const Duration(seconds: 180),
    ThumbnailSet(id),
    const [],
    const Engagement(0, null, null),
    false,
  );
}

class FakeEngine implements YouTubeEngine {
  final List<Video> songs;
  final List<Video> videos;
  final bool songsThrow;
  FakeEngine({this.songs = const [], this.videos = const [], this.songsThrow = false});

  @override
  Future<List<Video>> searchSongs(String query) async {
    if (songsThrow) throw Exception("music tab unavailable");
    return songs;
  }

  @override
  Future<List<Video>> searchVideos(String query) async => videos;

  @override
  Future<Video> getVideo(String videoId) => throw UnimplementedError();
  @override
  Future<StreamManifest> getStreamManifest(String videoId) =>
      throw UnimplementedError();
  @override
  Future<(Video, StreamManifest)> getVideoWithStreamInfo(String videoId) =>
      throw UnimplementedError();
  @override
  void dispose() {}
}

void main() {
  setUpAll(() => AppLogger.initialize(false));

  test("songs come first, then videos not already listed", () async {
    final engine = FakeEngine(
      songs: [video("aaaaaaaaaaa", "U&I", "Jersey")],
      videos: [
        video("bbbbbbbbbbb", "Jersey - U&I (Official Video)", "Jersey"),
        video("aaaaaaaaaaa", "U&I", "Jersey - Topic"), // same id as the song
        video("ccccccccccc", "Jersey - U&I (Lyrics)", "Lyrics Channel"),
      ],
    );

    final result = await searchYouTubeCleanFirst(engine, "Jersey U&I");

    expect(result.map((v) => v.id.value).toList(),
        ["aaaaaaaaaaa", "bbbbbbbbbbb", "ccccccccccc"]);
  });

  test("falls back to videos when the songs search fails", () async {
    final engine = FakeEngine(
      songsThrow: true,
      videos: [video("bbbbbbbbbbb", "Jersey - U&I (Official Video)", "Jersey")],
    );

    final result = await searchYouTubeCleanFirst(engine, "Jersey U&I");

    expect(result.length, 1);
    expect(result.first.id.value, "bbbbbbbbbbb");
  });

  test("returns videos when songs search is empty", () async {
    final engine = FakeEngine(
      videos: [video("ddddddddddd", "fan upload", "someone")],
    );

    final result = await searchYouTubeCleanFirst(engine, "obscure song");

    expect(result.map((v) => v.id.value).toList(), ["ddddddddddd"]);
  });
}

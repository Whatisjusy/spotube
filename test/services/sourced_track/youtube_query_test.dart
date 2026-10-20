import 'package:flutter_test/flutter_test.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/services/logger/logger.dart';
import 'package:spotube/services/sourced_track/sourced_track.dart';
import 'package:spotube/services/youtube_engine/youtube_engine.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

SpotubeFullTrackObject _track(String name, List<String> artists) {
  final a = artists
      .map((n) => SpotubeSimpleArtistObject(id: n, name: n, externalUri: ""))
      .toList();
  return SpotubeFullTrackObject(
    id: name,
    name: name,
    externalUri: "",
    artists: a,
    album: SpotubeSimpleAlbumObject(
      id: "a",
      name: "a",
      externalUri: "",
      artists: a,
      albumType: SpotubeAlbumType.single,
    ),
    durationMs: 0,
    isrc: "",
    explicit: false,
  );
}

Video _video(String id, String title, String author, int seconds) => Video(
      VideoId(id),
      title,
      author,
      ChannelId("UC_____________________$id".substring(0, 24)),
      null,
      null,
      null,
      "",
      Duration(seconds: seconds),
      ThumbnailSet(id),
      const [],
      const Engagement(0, null, null),
      false,
    );

/// Answers like YouTube did on 2026-10-20: nothing when the search holds
/// "VIP" or brackets, these uploads for the plain name.
class _YouTube implements YouTubeEngine {
  final queries = <String>[];
  @override
  Future<List<Video>> searchSongs(String query) async => [];
  @override
  Future<List<Video>> searchVideos(String query) async {
    queries.add(query);
    if (query.contains("(") || query.contains("VIP")) return [];
    return [
      _video(
          "aaaaaaaaaaa",
          "Angrybaby & Jon Casey - CLENCH MY FIST [Official Visualizer]",
          "Angrybaby and Jon Casey",
          196),
      _video(
          "bbbbbbbbbbb",
          "Jon Casey, Angrybaby - CLENCH MY FIST (Jon Casey VIP)",
          "broke records",
          187),
      _video("ccccccccccc", "CLENCH MY FIST (Jon Casey VIP)", "Jon Casey", 186),
    ];
  }

  @override
  Future<StreamManifest> getStreamManifest(String videoId) =>
      throw UnimplementedError();
  @override
  Future<Video> getVideo(String videoId) => throw UnimplementedError();
  @override
  Future<(Video, StreamManifest)> getVideoWithStreamInfo(String videoId) =>
      throw UnimplementedError();
  @override
  void dispose() {}
}

void main() {
  setUpAll(() => AppLogger.initialize(false));

  final vip =
      _track("CLENCH MY FIST (Jon Casey VIP)", ["Jon Casey", "Angrybaby"]);

  test("the plain search text drops the brackets", () {
    expect(SourcedTrack.youtubeSimpleQueryFor(vip),
        "Jon Casey Angrybaby CLENCH MY FIST");
  });

  test("an empty search is retried without brackets; the VIP still wins",
      () async {
    final youtube = _YouTube();
    final matches = await SourcedTrack.youtubeFallbackMatches(youtube, vip);

    expect(youtube.queries, [
      "Jon Casey Angrybaby CLENCH MY FIST (Jon Casey VIP)",
      "Jon Casey Angrybaby CLENCH MY FIST",
    ]);
    expect(matches.first.title, "CLENCH MY FIST (Jon Casey VIP)");
    expect(
        matches.map((m) => m.title), isNot(contains(contains("Visualizer"))));
  });

  test("a search that finds something is not repeated", () async {
    final youtube = _YouTube();
    await SourcedTrack.youtubeFallbackMatches(
        youtube, _track("Deviancy", ["Nikita, the Wicked"]));
    expect(youtube.queries, ["Nikita, the Wicked Deviancy"]);
  });
}

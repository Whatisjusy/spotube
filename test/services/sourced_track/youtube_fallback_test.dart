import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http_parser/http_parser.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/services/logger/logger.dart';
import 'package:spotube/services/sourced_track/audio_source_breaker.dart';
import 'package:spotube/services/sourced_track/sourced_track.dart';
import 'package:spotube/services/youtube_engine/youtube_engine.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

SpotubeFullTrackObject track(String name, String artist, int seconds) {
  final artists = [
    SpotubeSimpleArtistObject(id: artist, name: artist, externalUri: "")
  ];
  return SpotubeFullTrackObject(
    id: name,
    name: name,
    externalUri: "",
    artists: artists,
    album: SpotubeSimpleAlbumObject(
      id: "a",
      name: "a",
      externalUri: "",
      artists: artists,
      albumType: SpotubeAlbumType.single,
    ),
    durationMs: seconds * 1000,
    isrc: "",
    explicit: false,
  );
}

Video video(String id, String title, String author, int seconds) => Video(
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

StreamManifest manifestFor(String id) => StreamManifest([
      AudioOnlyStreamInfo(
        VideoId(id),
        251,
        Uri.parse("https://example.test/$id.webm"),
        StreamContainer.parse("webm"),
        FileSize.unknown,
        Bitrate(160000),
        "opus",
        "high",
        [],
        MediaType.parse("audio/webm"),
        null,
      ),
    ]);

class FakeEngine implements YouTubeEngine {
  final List<Video> songs;
  final List<String> manifestsRequested = [];
  FakeEngine({this.songs = const []});
  @override
  Future<List<Video>> searchSongs(String query) async => songs;
  @override
  Future<List<Video>> searchVideos(String query) async => [];
  @override
  Future<StreamManifest> getStreamManifest(String videoId) async {
    manifestsRequested.add(videoId);
    return manifestFor(videoId);
  }

  @override
  Future<Video> getVideo(String videoId) => throw UnimplementedError();
  @override
  Future<(Video, StreamManifest)> getVideoWithStreamInfo(String videoId) =>
      throw UnimplementedError();
  @override
  void dispose() {}
}

final monochrome = SpotubeAudioSourceMatchObject(
  id: "monochrome:156369299315888128",
  title: "Follow Me",
  artists: ["Petit Biscuit"],
  duration: const Duration(microseconds: 280640),
  externalUri: "https://tracks.monochrome.st/track/156369299315888128",
);

void main() {
  setUpAll(() => AppLogger.initialize(false));

  group("youtubeVideoId", () {
    test("reads every id shape plugins use", () {
      expect(
        SourcedTrack.youtubeVideoId(SpotubeAudioSourceMatchObject(
          id: "youtube:vAF0udoFJgA",
          title: "",
          artists: [],
          duration: Duration.zero,
          externalUri: "https://youtube.com/watch?v=vAF0udoFJgA",
        )),
        "vAF0udoFJgA",
      );
      expect(
        SourcedTrack.youtubeVideoId(SpotubeAudioSourceMatchObject(
          id: "ZbjFZxdCDU0",
          title: "",
          artists: [],
          duration: Duration.zero,
          externalUri: "https://youtube.com/watch?v=ZbjFZxdCDU0",
        )),
        "ZbjFZxdCDU0",
      );
      expect(SourcedTrack.youtubeVideoId(monochrome), isNull);
    });
  });

  test("matchesFromVideos produces YouTube matches with a usable length", () {
    final m = SourcedTrack.matchesFromVideos(
        [video("vAF0udoFJgA", "U&I", "Jersey", 153)]);
    expect(SourcedTrack.isYouTubeMatch(m.first), isTrue);
    expect(SourcedTrack.youtubeVideoId(m.first), "vAF0udoFJgA");
    expect(SourcedTrack.matchSeconds(m.first), 153);
  });

  group("AudioSourceBreaker", () {
    test("opens after three timeouts in a row, closes after the cooldown", () {
      var now = DateTime(2026, 10, 20, 10);
      final b = AudioSourceBreaker(
        cooldown: const Duration(seconds: 60),
        now: () => now,
      );
      expect(b.recordTimeout(), isFalse);
      expect(b.recordTimeout(), isFalse);
      expect(b.isOpen, isFalse);
      expect(b.recordTimeout(), isTrue);
      expect(b.isOpen, isTrue);
      now = now.add(const Duration(seconds: 59));
      expect(b.isOpen, isTrue);
      now = now.add(const Duration(seconds: 2));
      expect(b.isOpen, isFalse, reason: "one probe call is allowed");
      expect(b.recordTimeout(), isTrue, reason: "probe failed: re-open");
      expect(b.isOpen, isTrue);
    });

    test("a success resets the count and closes it", () {
      final b = AudioSourceBreaker();
      b.recordTimeout();
      b.recordTimeout();
      b.recordSuccess();
      expect(b.consecutiveTimeouts, 0);
      expect(b.recordTimeout(), isFalse);
      b.recordTimeout();
      b.recordTimeout();
      expect(b.isOpen, isTrue);
      b.recordSuccess();
      expect(b.isOpen, isFalse);
    });
  });

  group("streamsWithFallback", () {
    test("returns the plugin's streams when it answers in time", () async {
      final engine = FakeEngine();
      final streams = await SourcedTrack.streamsWithFallback(
        pluginStreams: () async => [
          SpotubeAudioSourceStreamObject(
            url: "https://flac",
            container: "flac",
            type: SpotubeMediaCompressionType.lossless,
          ),
        ],
        match: monochrome,
        query: track("Follow Me", "Petit Biscuit", 280),
        engine: engine,
        hardLimit: const Duration(milliseconds: 200),
      );
      expect(streams.single.container, "flac");
      expect(engine.manifestsRequested, isEmpty);
    });

    test("on timeout for a non-YouTube match, finds the song on YouTube",
        () async {
      final engine = FakeEngine(songs: [
        video("vAF0udoFJgA", "Follow Me", "Petit Biscuit", 280),
      ]);
      final streams = await SourcedTrack.streamsWithFallback(
        pluginStreams: () =>
            Completer<List<SpotubeAudioSourceStreamObject>>().future,
        match: monochrome,
        query: track("Follow Me", "Petit Biscuit", 280),
        engine: engine,
        hardLimit: const Duration(milliseconds: 200),
      );
      expect(engine.manifestsRequested, ["vAF0udoFJgA"]);
      expect(streams.single.container, "webm");
      expect(streams.single.type, SpotubeMediaCompressionType.lossy);
    });

    test("on timeout for a YouTube match, streams that same video", () async {
      final engine = FakeEngine();
      final match = SpotubeAudioSourceMatchObject(
        id: "youtube:ZbjFZxdCDU0",
        title: "x",
        artists: ["y"],
        duration: Duration.zero,
        externalUri: "https://youtube.com/watch?v=ZbjFZxdCDU0",
      );
      await SourcedTrack.streamsWithFallback(
        pluginStreams: () =>
            Completer<List<SpotubeAudioSourceStreamObject>>().future,
        match: match,
        query: track("x", "y", 100),
        engine: engine,
        hardLimit: const Duration(milliseconds: 200),
      );
      expect(engine.manifestsRequested, ["ZbjFZxdCDU0"]);
    });

    test("skips the plugin while the breaker is open", () async {
      final engine = FakeEngine(songs: [
        video("vAF0udoFJgA", "Follow Me", "Petit Biscuit", 280),
      ]);
      final breaker = AudioSourceBreaker(threshold: 1);
      breaker.recordTimeout();
      var pluginCalled = false;
      final streams = await SourcedTrack.streamsWithFallback(
        pluginStreams: () async {
          pluginCalled = true;
          return [];
        },
        match: monochrome,
        query: track("Follow Me", "Petit Biscuit", 280),
        engine: engine,
        hardLimit: const Duration(milliseconds: 200),
        breaker: breaker,
      );
      expect(pluginCalled, isFalse);
      expect(engine.manifestsRequested, ["vAF0udoFJgA"]);
      expect(streams.single.container, "webm");
    });

    test("a plugin error for a non-YouTube match is not swallowed", () async {
      final engine = FakeEngine();
      expect(
        () => SourcedTrack.streamsWithFallback(
          pluginStreams: () async => throw Exception("Monochrome 521"),
          match: monochrome,
          query: track("Follow Me", "Petit Biscuit", 280),
          engine: engine,
          hardLimit: const Duration(milliseconds: 200),
        ),
        throwsException,
      );
    });
  });
}

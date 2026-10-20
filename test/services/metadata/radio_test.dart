import 'package:flutter_test/flutter_test.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/services/logger/logger.dart';
import 'package:spotube/services/metadata/radio.dart';

SpotubeFullTrackObject _track(String name, [String artist = "pluko"]) {
  final a = [
    SpotubeSimpleArtistObject(id: artist, name: artist, externalUri: "")
  ];
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

SpotubeSimplePlaylistObject _playlist(String id, String name) =>
    SpotubeSimplePlaylistObject(
      id: id,
      name: name,
      description: "",
      externalUri: "",
      owner: SpotubeUserObject(id: "spotify", name: "Spotify", externalUri: ""),
    );

void main() {
  setUpAll(() => AppLogger.initialize(false));
  final seed = _track("Gang Gang Gangland (feat. YG & Mozzy)", "Chef Boy");

  test("plays Spotify's \"<song> Radio\" playlist", () async {
    final asked = <String>[];
    final songs = await songsLike(
      seed,
      searchPlaylists: (q) async {
        asked.add(q);
        return [
          _playlist("p1", "Gangland Vibes"),
          _playlist("radio", "Gang Gang Gangland (feat. YG & Mozzy) Radio"),
        ];
      },
      playlistTracks: (id) async =>
          id == "radio" ? [_track("a"), _track("b")] : [],
      artistTopTracks: (_) async => throw StateError("not needed"),
    );
    expect(asked, ["Gang Gang Gangland (feat. YG & Mozzy) Radio"]);
    expect(songs.map((s) => s.name), ["a", "b"]);
  });

  test("no radio playlist: the artist's top songs", () async {
    final songs = await songsLike(
      seed,
      searchPlaylists: (_) async => [_playlist("p1", "Gangland Vibes")],
      playlistTracks: (_) async => throw StateError("not needed"),
      artistTopTracks: (id) async => id == "Chef Boy" ? [_track("top")] : [],
    );
    expect(songs.map((s) => s.name), ["top"]);
  });

  test("the radio playlist failing to load falls back too", () async {
    final songs = await songsLike(
      seed,
      searchPlaylists: (_) async =>
          [_playlist("radio", "Gang Gang Gangland (feat. YG & Mozzy) Radio")],
      playlistTracks: (_) async => throw Exception("429"),
      artistTopTracks: (_) async => [_track("top")],
    );
    expect(songs.map((s) => s.name), ["top"]);
  });

  test("everything failing gives no songs and no crash", () async {
    final songs = await songsLike(
      seed,
      searchPlaylists: (_) async => throw Exception("429"),
      playlistTracks: (_) async => throw Exception("429"),
      artistTopTracks: (_) async => throw Exception("429"),
    );
    expect(songs, isEmpty);
  });
}

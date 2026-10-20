import 'package:flutter_test/flutter_test.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/services/sourced_track/sourced_track.dart';

SpotubeFullTrackObject track({
  required String name,
  required List<String> artists,
  required int seconds,
}) {
  final artistObjects = artists
      .map((a) => SpotubeSimpleArtistObject(id: a, name: a, externalUri: ""))
      .toList();
  return SpotubeFullTrackObject(
    id: name,
    name: name,
    externalUri: "",
    artists: artistObjects,
    album: SpotubeSimpleAlbumObject(
      id: "album",
      name: "album",
      externalUri: "",
      artists: artistObjects,
      albumType: SpotubeAlbumType.single,
    ),
    durationMs: seconds * 1000,
    isrc: "",
    explicit: false,
  );
}

/// YouTube Audio plugin style: id is the video id, duration in seconds.
SpotubeAudioSourceMatchObject yt(String title, String channel, int seconds) {
  return SpotubeAudioSourceMatchObject(
    id: title.hashCode.toString(),
    title: title,
    artists: [channel],
    duration: Duration(microseconds: seconds),
    externalUri: "https://youtube.com/watch?v=${title.hashCode}",
  );
}

/// Monochrome style: id prefixed, duration in milliseconds, tidal-ish link.
SpotubeAudioSourceMatchObject flac(String title, String artist, int seconds) {
  return SpotubeAudioSourceMatchObject(
    id: "monochrome:${title.hashCode}",
    title: title,
    artists: [artist],
    duration: Duration(microseconds: seconds * 1000),
    externalUri: "https://tracks.monochrome.st/track/${title.hashCode}",
  );
}

void main() {
  group("rankResults", () {
    test("prefers Topic, then lyric video, over the official music video", () {
      final t = track(name: "U&I", artists: ["Jersey"], seconds: 188);
      final results = [
        yt("Jersey - U&I (Official Video)", "Jersey", 188),
        yt("Jersey - U&I (Lyrics)", "Random Lyrics Channel", 188),
        yt("U&I", "Jersey - Topic", 189),
        yt("Jersey - U&I (Live at Printworks)", "Jersey", 240),
      ];

      final ranked = SourcedTrack.rankResults(results, t);

      expect(ranked.map((m) => m.title).toList(), [
        "U&I",
        "Jersey - U&I (Lyrics)",
        "Jersey - U&I (Official Video)",
        "Jersey - U&I (Live at Printworks)",
      ]);
    });

    test("drops unrelated videos from a bad ISRC search", () {
      final t = track(name: "Death Whistle", artists: ["Viperactive"], seconds: 125);
      final results = [
        yt("Best budget phones 2026 review", "GadgetGuy", 600),
        yt("Death Whistle", "Viperactive", 125),
      ];

      final ranked = SourcedTrack.rankResults(results, t);

      expect(ranked.map((m) => m.title).toList(), ["Death Whistle"]);
    });

    test("keeps everything when nothing looks plausible", () {
      final t = track(name: "Nakal", artists: ["Halogenix"], seconds: 184);
      final results = [
        yt("Something else entirely", "A", 100),
        yt("Another unrelated thing", "B", 200),
      ];

      expect(SourcedTrack.rankResults(results, t).length, 2);
    });

    test("does not reorder lossless catalogue matches, keeps them first", () {
      final t = track(name: "Follow Me", artists: ["Petit Biscuit"], seconds: 280);
      final results = [
        flac("Follow Me", "Petit Biscuit", 280),
        flac("Follow Me (Edit)", "Petit Biscuit", 200),
        yt("Follow Me", "Petit Biscuit - Topic", 280),
      ];

      final ranked = SourcedTrack.rankResults(results, t);

      expect(ranked.map((m) => m.id).toList(), [
        results[0].id,
        results[1].id,
        results[2].id,
      ]);
    });

    test("does not penalise a word that is in the Spotify title", () {
      final t = track(
        name: "immortal - Snakehips Remix",
        artists: ["KIDS SEE GHOSTS", "Snakehips"],
        seconds: 200,
      );
      final remix = yt("immortal - Snakehips Remix", "Snakehips - Topic", 200);
      final original = yt("immortal (Official Audio)", "KIDS SEE GHOSTS", 220);

      final ranked = SourcedTrack.rankResults([original, remix], t);

      expect(ranked.first.title, remix.title);
    });

    test("ranks non-English titles too", () {
      final t = track(name: "C'est la cité", artists: ["Jul"], seconds: 190);
      final results = [
        yt("Jul - C'est La Cite (Clip Officiel) [Official Video]", "Jul", 190),
        yt("C'est la cité", "Jul - Topic", 190),
      ];

      expect(SourcedTrack.rankResults(results, t).first.title, "C'est la cité");
    });
  });

  test("matchSeconds guesses the unit", () {
    expect(SourcedTrack.matchSeconds(yt("a", "b", 167)), 167);
    expect(SourcedTrack.matchSeconds(flac("a", "b", 280)), 280);
    expect(
      SourcedTrack.matchSeconds(SpotubeAudioSourceMatchObject(
        id: "x",
        title: "x",
        artists: [],
        duration: const Duration(seconds: 300),
        externalUri: "",
      )),
      300,
    );
  });

  group("artist check", () {
    // Phone log 2026-10-20 16:20:16, real YouTube results. The Spotify list
    // had no lengths (durationMs 0), so only the artist could tell them
    // apart, and another artist's Topic upload won 9 to 5.
    test("another artist's same-named song loses to the real one", () {
      final t = track(name: "I FEEL STRANGE", artists: ["pluko"], seconds: 0);
      final results = [
        yt("I FEEL STRANGE", "pluko", 0),
        yt("pluko  -  I FEEL STRANGE", "Cresta La Cultura", 0),
        yt("I Feel Strange (feat. Cam Sully)", "Ccapöne - Topic", 0),
      ];

      final ranked = SourcedTrack.rankResults(results, t);

      expect(ranked.first.title, "I FEEL STRANGE");
      expect(ranked.last.title, "I Feel Strange (feat. Cam Sully)");
    });

    test("the song's own Topic upload still wins, for any of its artists", () {
      final t = track(
        name: "CLENCH MY FIST (Jon Casey VIP)",
        artists: ["Jon Casey", "Angrybaby"],
        seconds: 0,
      );
      final results = [
        yt("Jon Casey - CLENCH MY FIST (Jon Casey VIP)", "Jon Casey", 0),
        yt("CLENCH MY FIST (Jon Casey VIP)", "Angrybaby - Topic", 0),
      ];

      final ranked = SourcedTrack.rankResults(results, t);

      expect(ranked.first.artists.first, "Angrybaby - Topic");
    });
  });

  group("featured artists in the song name", () {
    // Real YouTube results, 2026-10-20. Spotify's name carries "(feat. ...)",
    // the uploads do not, so they were all dropped and a mashup was played.
    final gangland = [
      yt("Chef Boy, Mozzy, YG & E-40 - Gang Gang Gangland (AUDIO)", "DatPiff", 190),
      yt("Chef Boy - Gang Gang (Official Video) ft Rosecrans hopout, YS, PhoPho8ight & Hitta J3", "Chef Boy", 228),
      yt("Chef boy, Mozzy, YG & E-40 - \"Gang Gang Gangland\" OFFICIAL VERSION", "StrictlyHits", 190),
      yt("Chef Boy, Mozzy, YG & E-40 - Gang Gang Gangland (lyrics)", "Ttendosamuel45 Rap", 190),
      yt("Gang Gang Gangland feat. YG & Mozzy (KDS Mashup)", "Kick Drum Safari", 249),
    ];

    for (final seconds in [0, 190]) {
      test("the real song beats the mashup (length ${seconds}s)", () {
        final t = track(
          name: "Gang Gang Gangland (feat. YG & Mozzy)",
          artists: ["Chef Boy", "E-40", "YG", "Mozzy"],
          seconds: seconds,
        );

        final ranked = SourcedTrack.rankResults(gangland, t);

        expect(ranked.first.title, startsWith("Chef Boy, Mozzy, YG & E-40"));
        expect(ranked.last.title, contains("Mashup"));
      });
    }

    test("a (with ...) that is part of the title is kept", () {
      expect(
        SourcedTrack.coreName(track(name: "W U (With You)", artists: ["JEV"], seconds: 0)),
        "w u with you",
      );
      expect(
        SourcedTrack.coreName(track(
          name: "feet2myface (with Allegra Miles)",
          artists: ["informal.", "Allegra Miles"],
          seconds: 0,
        )),
        "feet2myface",
      );
    });
  });
}

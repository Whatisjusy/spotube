import 'package:flutter_test/flutter_test.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/provider/audio_player/audio_player.dart';

SpotubeTrackObject _t(String id) => SpotubeFullTrackObject(
      id: id,
      name: id,
      externalUri: "",
      artists: [],
      album: SpotubeSimpleAlbumObject(
        id: "a",
        name: "a",
        externalUri: "",
        artists: [],
        albumType: SpotubeAlbumType.single,
      ),
      durationMs: 1000,
      isrc: "",
      explicit: false,
    );

List<String> _ids(List<SpotubeTrackObject> tracks) =>
    tracks.map((t) => t.id).toList();

void main() {
  final queue = ["a", "b", "c", "d", "e"].map(_t).toList();

  test("a searched song goes straight after the current one", () {
    final (tracks, index) = queueWithPlayNow(queue, 1, _t("fox"));
    expect(_ids(tracks), ["a", "b", "fox", "c", "d", "e"]);
    expect(index, 2);
  });

  test("a song already later in the queue is moved, not doubled", () {
    final (tracks, index) = queueWithPlayNow(queue, 1, _t("d"));
    expect(_ids(tracks), ["a", "b", "d", "c", "e"]);
    expect(index, 2);
  });

  test("a song already played earlier is moved too", () {
    final (tracks, index) = queueWithPlayNow(queue, 3, _t("a"));
    expect(_ids(tracks), ["b", "c", "d", "a", "e"]);
    expect(index, 3);
  });

  test("at the last song it plays next with nothing after it", () {
    final (tracks, index) = queueWithPlayNow(queue, 4, _t("fox"));
    expect(_ids(tracks), ["a", "b", "c", "d", "e", "fox"]);
    expect(index, 5);
  });

  test("an empty queue becomes just that song", () {
    final (tracks, index) = queueWithPlayNow([], 0, _t("fox"));
    expect(_ids(tracks), ["fox"]);
    expect(index, 0);
  });
}

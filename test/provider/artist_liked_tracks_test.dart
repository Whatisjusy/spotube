import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/provider/metadata_plugin/core/auth.dart';
import 'package:spotube/provider/metadata_plugin/library/tracks.dart';
import 'package:spotube/services/logger/logger.dart';

// Logged out, so Liked Songs is not loaded from the plugin.
class _LoggedOut extends MetadataPluginAuthenticatedNotifier {
  @override
  build() => false;
}

SpotubeSimpleArtistObject _artist(String id) =>
    SpotubeSimpleArtistObject(id: id, name: id, externalUri: "");

SpotubeFullTrackObject _track(String id, List<String> artistIds) =>
    SpotubeTrackObject.full(
      id: id,
      name: id,
      externalUri: "",
      artists: artistIds.map(_artist).toList(),
      album: SpotubeSimpleAlbumObject(
        id: "album",
        name: "album",
        externalUri: "",
        artists: const [],
        albumType: SpotubeAlbumType.album,
      ),
      durationMs: 1000,
      isrc: "",
      explicit: false,
    ) as SpotubeFullTrackObject;

void main() {
  setUpAll(() => AppLogger.initialize(false));

  ProviderContainer makeContainer() {
    final container = ProviderContainer(overrides: [
      metadataPluginAuthenticatedProvider.overrideWith(_LoggedOut.new),
    ]);
    addTearDown(container.dispose);
    container.listen(likedTrackIdsProvider, (_, __) {});
    return container;
  }

  List<String> likedBy(ProviderContainer c, String artistId) => c
      .read(artistLikedTracksProvider(artistId))
      .tracks
      .map((t) => t.id)
      .toList();

  test("only songs by that artist, including features", () {
    final c = makeContainer();
    c.read(likedTrackIdsProvider.notifier).mark([
      _track("solo", ["drake"]),
      _track("other", ["sza"]),
      _track("feature", ["sza", "drake"]),
    ], liked: true);

    expect(likedBy(c, "drake"), ["solo", "feature"]);
    expect(likedBy(c, "sza"), ["other", "feature"]);
    expect(likedBy(c, "nobody"), isEmpty);
  });

  test("a newly liked song goes on top; an unliked one disappears", () {
    final c = makeContainer();
    final notifier = c.read(likedTrackIdsProvider.notifier);
    notifier.mark([_track("old", ["drake"])], liked: true);
    notifier.mark([_track("new", ["drake"])], liked: true);
    expect(likedBy(c, "drake"), ["new", "old"]);

    notifier.mark([_track("old", ["drake"])], liked: false);
    expect(likedBy(c, "drake"), ["new"]);
    expect(c.read(isTrackLikedProvider("old")), isFalse);
  });

  test("liking the same song twice does not list it twice", () {
    final c = makeContainer();
    final notifier = c.read(likedTrackIdsProvider.notifier);
    notifier.mark([_track("song", ["drake"])], liked: true);
    notifier.mark([_track("song", ["drake"])], liked: true);
    expect(likedBy(c, "drake"), ["song"]);
  });
}

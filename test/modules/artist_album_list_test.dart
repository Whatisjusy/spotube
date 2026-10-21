import 'package:flutter_test/flutter_test.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/modules/artist/artist_album_list.dart';

SpotubeSimpleAlbumObject album(String id,
        {List<SpotubeSimpleArtistObject> artists = const []}) =>
    SpotubeSimpleAlbumObject(
      id: id,
      name: "Album $id",
      externalUri: "https://open.spotify.com/album/$id",
      artists: artists,
      albumType: SpotubeAlbumType.album,
    );

final bmth = SpotubeFullArtistObject(
  id: "bmth",
  name: "Bring Me The Horizon",
  externalUri: "https://open.spotify.com/artist/bmth",
);

void main() {
  test("an album with no artists gets the page's artist", () {
    final result = albumsWithArtist([album("a")], bmth);
    expect(result.single.artists.single.name, "Bring Me The Horizon");
    expect(result.single.artists.single.id, "bmth");
  });

  test("an album that already has artists is left alone", () {
    final other = SpotubeSimpleArtistObject(
      id: "x",
      name: "Someone Else",
      externalUri: "https://open.spotify.com/artist/x",
    );
    final result = albumsWithArtist([album("a", artists: [other])], bmth);
    expect(result.single.artists.single.name, "Someone Else");
  });

  test("albums are unchanged while the artist is still loading", () {
    final albums = [album("a")];
    expect(albumsWithArtist(albums, null), same(albums));
  });
}

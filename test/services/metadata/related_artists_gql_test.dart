import 'package:flutter_test/flutter_test.dart';
import 'package:spotube/services/metadata/endpoints/artist.dart';

Map<String, dynamic> _reply(List<Map<String, dynamic>> items) => {
      "data": {
        "artistUnion": {
          "__typename": "Artist",
          "relatedContent": {
            "relatedArtists": {"totalCount": items.length, "items": items},
          },
        },
      },
      "extensions": {},
    };

void main() {
  group("relatedArtistsFromGql", () {
    test("reads id, name, link and pictures", () {
      final artists = relatedArtistsFromGql(_reply([
        {
          "id": "20JZFwl6HVl6yg8a4H3ZqK",
          "profile": {"name": "Panic! At The Disco"},
          "uri": "spotify:artist:20JZFwl6HVl6yg8a4H3ZqK",
          "visuals": {
            "avatarImage": {
              "sources": [
                {"height": 640, "url": "https://i.scdn.co/a", "width": 640},
                {"height": 160, "url": "https://i.scdn.co/b", "width": 160},
              ],
            },
          },
        },
      ]));

      expect(artists, hasLength(1));
      final a = artists.single;
      expect(a.id, "20JZFwl6HVl6yg8a4H3ZqK");
      expect(a.name, "Panic! At The Disco");
      expect(a.externalUri,
          "https://open.spotify.com/artist/20JZFwl6HVl6yg8a4H3ZqK");
      expect(a.images.map((i) => i.url),
          ["https://i.scdn.co/a", "https://i.scdn.co/b"]);
      expect(a.images.first.width, 640);
    });

    test("takes the id from the uri when there is no id, skips entries with neither",
        () {
      final artists = relatedArtistsFromGql(_reply([
        {
          "profile": {"name": "Porter Robinson"},
          "uri": "spotify:artist:3dz0NnIZhtKKeXZxLOxCam",
        },
        {"profile": {"name": "nobody"}},
      ]));

      expect(artists.map((a) => a.id), ["3dz0NnIZhtKKeXZxLOxCam"]);
      expect(artists.single.images, isEmpty);
    });

    test("an error reply throws, so the plugin's own call is used instead", () {
      expect(
        () => relatedArtistsFromGql({
          "errors": [
            {"message": "PersistedQueryNotFound"}
          ],
        }),
        throwsFormatException,
      );
      expect(() => relatedArtistsFromGql("<html>"), throwsFormatException);
    });
  });
}

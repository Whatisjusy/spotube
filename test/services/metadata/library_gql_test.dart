import 'package:flutter_test/flutter_test.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/services/metadata/endpoints/user.dart';

Map<String, dynamic> _library(
  List<Map<String, dynamic>> data, {
  int offset = 0,
  int limit = 20,
  int? total,
}) =>
    {
      "data": {
        "me": {
          "libraryV3": {
            "__typename": "LibraryPage",
            "items": [
              for (final d in data)
                {
                  "item": {"_uri": d["uri"], "data": d},
                },
            ],
            "pagingInfo": {"offset": offset, "limit": limit},
            "totalCount": total ?? data.length,
          },
        },
      },
    };

final _artist = {
  "__typename": "Artist",
  "profile": {"name": "Twenty One Pilots"},
  "uri": "spotify:artist:3YQKmKGau1PzlVlkL1iodx",
  "visuals": {
    "avatarImage": {
      "sources": [
        {"height": 640, "url": "https://i.scdn.co/a", "width": 640},
      ],
    },
  },
};

final _album = {
  "__typename": "Album",
  "artists": {
    "items": [
      {
        "profile": {"name": "Warfaze"},
        "uri": "spotify:artist:06eRdiCBgFUhiuFjei0eH2",
      },
    ],
  },
  "coverArt": {
    "sources": [
      {"height": 300, "url": "https://i.scdn.co/c", "width": 300},
    ],
  },
  "date": {"isoString": "2012-10-12T00:00:00Z", "precision": "DAY"},
  "name": "Shotto",
  "type": "ALBUM",
  "uri": "spotify:album:6arzq3H2uuaYsfBBe2BYC3",
};

void main() {
  group("library artists", () {
    test("reads name, id and picture", () {
      final page =
          libraryPageFromGql(_library([_artist]), libraryArtistFromGql);
      final a = page.items.single;
      expect(a.id, "3YQKmKGau1PzlVlkL1iodx");
      expect(a.name, "Twenty One Pilots");
      expect(a.images.single.url, "https://i.scdn.co/a");
      expect(page.hasMore, isFalse);
      expect(page.nextOffset, isNull);
    });

    test("skips other kinds of items", () {
      final page = libraryPageFromGql(
        _library([
          _artist,
          {"__typename": "Playlist", "uri": "spotify:playlist:x"},
        ]),
        libraryArtistFromGql,
      );
      expect(page.items.map((a) => a.name), ["Twenty One Pilots"]);
    });

    test("an artist without a name throws, so the plugin's call is used", () {
      expect(
        () => libraryPageFromGql(
          _library([
            {"__typename": "Artist", "uri": "spotify:artist:abc"},
          ]),
          libraryArtistFromGql,
        ),
        throwsFormatException,
      );
    });
  });

  group("library albums", () {
    test("reads name, artists, cover, type and date", () {
      final album = libraryPageFromGql(_library([_album]), libraryAlbumFromGql)
          .items
          .single;
      expect(album.id, "6arzq3H2uuaYsfBBe2BYC3");
      expect(album.name, "Shotto");
      expect(album.artists.single.name, "Warfaze");
      expect(album.artists.single.id, "06eRdiCBgFUhiuFjei0eH2");
      expect(album.images.single.url, "https://i.scdn.co/c");
      expect(album.albumType, SpotubeAlbumType.album);
      expect(album.releaseDate, "2012-10-12");
    });

    test("singles and EPs keep the plugin's types; year-only dates stay a year",
        () {
      final page = libraryPageFromGql(
        _library([
          {..._album, "type": "SINGLE"},
          {
            ..._album,
            "type": "EP",
            "date": {"isoString": "2019-01-01T00:00:00Z", "precision": "YEAR"},
          },
        ]),
        libraryAlbumFromGql,
      );
      expect(page.items.map((a) => a.albumType),
          [SpotubeAlbumType.single, SpotubeAlbumType.compilation]);
      expect(page.items.last.releaseDate, "2019");
    });
  });

  group("paging", () {
    test("more pages: next offset follows the items received", () {
      final page = libraryPageFromGql(
        _library([_artist, _artist], offset: 20, total: 45),
        libraryArtistFromGql,
      );
      expect(page.hasMore, isTrue);
      expect(page.nextOffset, 22);
      expect(page.total, 45);
    });

    test("an empty page never claims more, so load-all cannot loop", () {
      final page = libraryPageFromGql(
        _library([], offset: 40, total: 45),
        libraryArtistFromGql,
      );
      expect(page.hasMore, isFalse);
      expect(page.nextOffset, isNull);
    });

    test("an error reply throws", () {
      expect(
        () => libraryPageFromGql({"errors": []}, libraryArtistFromGql),
        throwsFormatException,
      );
    });
  });
}

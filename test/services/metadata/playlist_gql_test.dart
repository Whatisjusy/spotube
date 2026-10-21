import 'package:flutter_test/flutter_test.dart';
import 'package:spotube/services/metadata/endpoints/playlist.dart';

// Replies below are the samples in the Spotify plugin's Kotlin tests
// (spotify_gql_client/src/commonTest/resources/*_200.json).

Map<String, dynamic> _row(String uid, Map<String, dynamic> data) => {
      "uid": uid,
      "itemV2": {
        "__typename": "${data["__typename"]}ResponseWrapper",
        "data": data
      },
    };

Map<String, dynamic> _page(List<Map<String, dynamic>> rows, {int? total}) => {
      "data": {
        "playlistV2": {
          "content": {
            "__typename": "PlaylistItemsPage",
            "items": rows,
            "pagingInfo": {"limit": 25, "offset": 0},
            "totalCount": total ?? rows.length,
          },
        },
      },
    };

void main() {
  group("request bodies", () {
    test("create sends name and description as list attributes", () {
      expect(
        createPlaylistBody(name: "Spotube test", description: "x"),
        {
          "ops": [
            {
              "kind": "UPDATE_LIST_ATTRIBUTES",
              "updateListAttributes": {
                "newAttributes": {
                  "values": {"name": "Spotube test", "description": "x"},
                },
              },
            },
          ],
        },
      );
    });

    test("create leaves out a missing description", () {
      final values = createPlaylistBody(name: "a")["ops"][0]
          ["updateListAttributes"]["newAttributes"]["values"];
      expect(values, {"name": "a"});
    });

    test("update sends only what changed, as one delta", () {
      final body = updatePlaylistBody(description: "new");
      expect(body, {
        "deltas": [
          {
            "ops": [
              {
                "kind": "UPDATE_LIST_ATTRIBUTES",
                "updateListAttributes": {
                  "newAttributes": {
                    "values": {"description": "new"},
                  },
                },
              },
            ],
            "info": {
              "source": {"client": "WEBPLAYER"},
            },
          },
        ],
      });
    });

    test("public flag is an attribute of the playlist's Library entry", () {
      expect(publicChangeBody("abc", false), {
        "deltas": [
          {
            "ops": [
              {
                "kind": "UPDATE_ITEM_ATTRIBUTES",
                "updateItemAttributes": {
                  "newAttributes": {
                    "values": {"public": false},
                  },
                  "item": {"uri": "spotify:playlist:abc"},
                },
              },
            ],
            "info": {
              "source": {"client": "WEBPLAYER"},
            },
          },
        ],
      });
    });

    test("add puts the songs at the end", () {
      expect(addToPlaylistVariables("pl", ["t1", "t2"]), {
        "playlistItemUris": ["spotify:track:t1", "spotify:track:t2"],
        "playlistUri": "spotify:playlist:pl",
        "newPosition": {"moveType": "BOTTOM_OF_PLAYLIST", "fromUid": null},
      });
    });
  });

  group("replies", () {
    test("create reply gives the new playlist's id", () {
      expect(
        createdPlaylistIdFromReply({
          "uri": "spotify:playlist:34bc8BvPoIyXEk24bZjizQ",
          "revision": "AAAAAd4Xlit2qo4WNbRLKxaiq/XGeHPA",
        }),
        "34bc8BvPoIyXEk24bZjizQ",
      );
    });

    test("create reply without a playlist is an error", () {
      expect(
        () => createdPlaylistIdFromReply({"error": "nope"}),
        throwsFormatException,
      );
      expect(
        () => createdPlaylistIdFromReply({"uri": "spotify:playlist:"}),
        throwsFormatException,
      );
    });

    test("change reply gives the new revision", () {
      expect(
        revisionFromReply({
          "revision": "AAAAAiIAYKbF42kk3PfMtJd7YQqjivk4",
          "syncResult": {
            "fromRevision": "AAAAAiIAYKbF42kk3PfMtJd7YQqjivk4",
            "toRevision": "AAAAAiIAYKbF42kk3PfMtJd7YQqjivk4",
          },
          "resultingRevisions": ["AAAAAiIAYKbF42kk3PfMtJd7YQqjivk4"],
          "multipleHeads": false,
          "changesRequireResync": false,
        }),
        "AAAAAiIAYKbF42kk3PfMtJd7YQqjivk4",
      );
      expect(() => revisionFromReply(""), throwsFormatException);
    });

    test("query-server changes are checked by their result", () {
      for (final (reply, field) in [
        (
          {
            "data": {
              "addItemsToPlaylist": {"__typename": "AddItemsToPlaylistPayload"},
            },
          },
          "addItemsToPlaylist"
        ),
        (
          {
            "data": {
              "removeItemsFromPlaylist": {
                "__typename": "RemoveItemsFromPlaylistPayload",
              },
            },
          },
          "removeItemsFromPlaylist"
        ),
        (
          {
            "data": {
              "addItemsToRootlist": {
                "__typename": "RootlistItemMutationResult",
              },
            },
          },
          "addItemsToRootlist"
        ),
        (
          {
            "data": {
              "removeItemsFromRootlist": {
                "__typename": "RootlistItemMutationResult",
              },
            },
          },
          "removeItemsFromRootlist"
        ),
      ]) {
        expect(() => expectMutationReply(reply, field), returnsNormally);
      }
    });

    test("a refused change is an error, not a success", () {
      expect(
        () => expectMutationReply({
          "errors": [
            {"message": "PersistedQueryNotFound"},
          ],
          "data": null,
        }, "addItemsToPlaylist"),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            "message",
            contains("PersistedQueryNotFound"),
          ),
        ),
      );
      expect(
        () => expectMutationReply({
          "data": {"addItemsToPlaylist": null},
        }, "addItemsToPlaylist"),
        throwsFormatException,
      );
      // The other operation's result does not count.
      expect(
        () => expectMutationReply({
          "data": {
            "addItemsToRootlist": {"__typename": "RootlistItemMutationResult"},
          },
        }, "removeItemsFromRootlist"),
        throwsFormatException,
      );
    });
  });

  group("playlist rows", () {
    test("reads row ids and song ids", () {
      final page = playlistRowsFromGql(_page([
        _row("65366334663265623737346263353761", {
          "__typename": "Track",
          "uri": "spotify:track:2Z8WuEywRWYTKe1NybPQEW",
          "name": "Ride",
        }),
        _row("ep1", {
          "__typename": "Episode",
          "uri": "spotify:episode:xyz",
        }),
      ], total: 50));
      expect(page.total, 50);
      expect(page.rows, [
        (
          uid: "65366334663265623737346263353761",
          trackId: "2Z8WuEywRWYTKe1NybPQEW"
        ),
        (uid: "ep1", trackId: null),
      ]);
    });

    test("a row without uid is an error, so nothing is removed by guess", () {
      expect(
        () => playlistRowsFromGql(_page([
          {
            "itemV2": {
              "data": {"uri": "spotify:track:a"},
            },
          },
        ])),
        throwsFormatException,
      );
    });

    test("a reply without items is an error", () {
      expect(
        () => playlistRowsFromGql({
          "errors": [
            {"message": "boom"},
          ],
        }),
        throwsFormatException,
      );
    });
  });
}

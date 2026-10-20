import 'package:flutter_test/flutter_test.dart';
import 'package:spotube/services/logger/logger.dart';
import 'package:spotube/services/metadata/endpoints/search.dart';
import 'package:spotube/models/metadata/metadata.dart';

/// What the Spotify plugin 0.2.2 hands back for one search page, worked out
/// the way its code does (spotify-gql-client search.ht passes Spotify's
/// `nextOffset` as `offset`; converter.ht `paginated` then adds to it).
SpotubePaginationResponseObject<int> pluginPage({
  required int offset,
  required int limit,
  required int total,
}) {
  final count = (total - offset).clamp(0, limit);
  final spotifyNext = offset + limit < total ? offset + limit : null;
  if (spotifyNext == null) {
    // null + count: the crash seen on the phone.
    throw Exception(_phoneCrash);
  }
  final hasMore = total > spotifyNext + count;
  return SpotubePaginationResponseObject<int>(
    limit: limit,
    nextOffset: hasMore ? spotifyNext + limit : null,
    total: total,
    hasMore: hasMore,
    items: List.generate(count, (i) => offset + i),
  );
}

// From the phone log, 2026-10-20 16:14:52.
const _phoneCrash =
    "File: /home/runner/work/spotube-plugin-spotify/spotube-plugin-spotify/"
    "src/converter/converter.ht\nLine: 2, Column: 79\nRuntime error: extern\n"
    "Message: NoSuchMethodError: The method '+' was called on null.\n"
    "Receiver: null\nTried calling: +(20)";

Future<SpotubePaginationResponseObject<int>> tab(int offset, int total) {
  return searchPageWithFallback<int>(
    label: "test",
    offset: offset,
    limit: 20,
    page: () async => pluginPage(offset: offset, limit: 20, total: total),
    fromAll: () async => List.generate(total.clamp(0, 20), (i) => 1000 + i),
  );
}

void main() {
  setUpAll(() => AppLogger.initialize(false));

  test("recognises the phone's crash and nothing else", () {
    expect(isPluginLastPageCrash(Exception(_phoneCrash)), isTrue);
    expect(isPluginLastPageCrash(Exception("429 Too Many Requests")), isFalse);
  });

  test("a search with 20 or fewer results shows the All search's results",
      () async {
    expect(() => pluginPage(offset: 0, limit: 20, total: 7), throwsException);

    final page = await tab(0, 7);
    expect(page.items, List.generate(7, (i) => 1000 + i));
    expect(page.hasMore, isFalse);
  });

  test("load more no longer skips a page", () async {
    final plugin = pluginPage(offset: 0, limit: 20, total: 100);
    expect(plugin.nextOffset, 40); // skipped 20-39

    final first = await tab(0, 100);
    expect(first.nextOffset, 20);
    final second = await tab(first.nextOffset!, 100);
    expect(second.items.first, 20);
  });

  test("21-39 results offer a second page", () async {
    expect(pluginPage(offset: 0, limit: 20, total: 25).hasMore, isFalse);

    final first = await tab(0, 25);
    expect(first.hasMore, isTrue);
    expect(first.nextOffset, 20);
  });

  test("the plugin crashing on a later page ends the list", () async {
    final last = await tab(80, 100);
    expect(last.items, isEmpty);
    expect(last.hasMore, isFalse);
  });

  test("other errors still come through", () async {
    await expectLater(
      searchPageWithFallback<int>(
        label: "test",
        offset: 0,
        limit: 20,
        page: () async => throw Exception("429 Too Many Requests"),
        fromAll: () async => [1],
      ),
      throwsException,
    );
  });
}

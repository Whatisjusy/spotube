import 'package:flutter_test/flutter_test.dart';
import 'package:spotube/services/youtube_engine/youtube_explode_engine.dart';

void main() {
  test("search durations", () {
    expect(parseSearchDuration("3:45"), const Duration(minutes: 3, seconds: 45));
    expect(parseSearchDuration("1:02:03"),
        const Duration(hours: 1, minutes: 2, seconds: 3));
    expect(parseSearchDuration(""), isNull);
    expect(parseSearchDuration("LIVE"), isNull);
  });

  // Live: both queries returned a "Streamed 3w ago" / "Streamed 3y ago" result
  // on 2026-10-20 that made youtube_explode's search throw FormatException.
  for (final q in ["wes mills my love 4 u", "Fred again Boiler Room"]) {
    test("search survives livestream dates: $q", () async {
      final videos = await YouTubeExplodeEngine().searchVideos(q);
      expect(videos, isNotEmpty);
      expect(videos.where((v) => v.duration != null), isNotEmpty);
    }, tags: ["live"], timeout: const Timeout(Duration(seconds: 60)));
  }
}

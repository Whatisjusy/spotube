@Tags(["live"])
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotube/services/youtube_engine/youtube_explode_engine.dart';

/// Live: talks to YouTube. A failed call must come back as an error, and the
/// worker must keep answering afterwards.
void main() {
  test("a failing lookup reports its error and the worker survives", () async {
    await IsolatedYoutubeExplode.initialize();
    final yt = IsolatedYoutubeExplode.instance;

    await expectLater(
      yt.video("xxxxxxxxxxx").timeout(const Duration(seconds: 20)),
      throwsA(isNot(isA<TimeoutException>())),
    );

    final results = await yt
        .search("Daniel Allan Safe")
        .timeout(const Duration(seconds: 20));
    expect(results, isNotEmpty);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test("a new session keeps answering, and calls already running finish",
      () async {
    await IsolatedYoutubeExplode.initialize();
    final yt = IsolatedYoutubeExplode.instance;

    final running = yt.search("Daniel Allan Safe");
    await yt.resetSession().timeout(const Duration(seconds: 5));
    expect(await running.timeout(const Duration(seconds: 20)), isNotEmpty);

    final after = await yt
        .search("Chris Lake Reach For You")
        .timeout(const Duration(seconds: 20));
    expect(after, isNotEmpty);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test("the phone's robot-check error is recognised", () {
    // Copied from the phone log, 2026-10-20 15:55:37.
    const phone = "ClientException: Redirect limit exceeded, "
        "uri=https://www.youtube.com/results?search_query=dunne+chance"
        "&sp=EgIQAQ%253D%253D&google_abuse=GOOGLE_ABUSE_EXEMPTION%3DID%3D"
        "ca4cd452b27883ac:TM%3D1792486536";
    expect(YouTubeExplodeEngine.isRobotCheck(Exception(phone)), isTrue);
    // 16:01:41, the same refusal reported as a rate limit.
    const phone2 = "RequestLimitExceededException: Failed to perform an HTTP "
        "request to YouTube because of rate limiting.";
    expect(YouTubeExplodeEngine.isRobotCheck(Exception(phone2)), isTrue);
    expect(
      YouTubeExplodeEngine.isRobotCheck(
          Exception("Failed to retrieve initial data from SearchPage")),
      isFalse,
    );
  });
}

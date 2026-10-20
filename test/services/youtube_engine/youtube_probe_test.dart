@Tags(["live"])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:spotube/services/youtube_engine/youtube_probe.dart';

/// Live: from a network Google does not flag, every probe must say "ok".
/// Proves the probes themselves are right before trusting them on a phone.
void main() {
  test("all YouTube probes pass from an unflagged network", () async {
    final results = await probeYouTube();
    for (final r in results) {
      // ignore: avoid_print
      print(r);
    }
    expect(results, hasLength(5));
    expect(results.where((r) => !r.contains(": ok (")), isEmpty);
  }, timeout: const Timeout(Duration(seconds: 90)));
}

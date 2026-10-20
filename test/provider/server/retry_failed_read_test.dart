import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:spotube/provider/server/sourced_track_provider.dart';
import 'package:spotube/services/logger/logger.dart';

// Stands in for sourcedTrackProvider: the first lookup of a song fails (a
// YouTube hiccup), later ones work.
var lookups = 0;
final _lookup = FutureProvider.family<String, String>((ref, song) async {
  if (lookups++ == 0) throw Exception("TrackNotFoundError $song");
  return "audio for $song";
});

void main() {
  setUpAll(() => AppLogger.initialize(false));
  setUp(() => lookups = 0);

  test("a failed lookup stays failed when it is only read again", () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.listen(_lookup("Deviancy"), (_, __) {});

    await expectLater(
        container.read(_lookup("Deviancy").future), throwsException);
    // The song comes up later: same provider, same failure, no new lookup.
    await expectLater(
        container.read(_lookup("Deviancy").future), throwsException);
    expect(lookups, 1);
  });

  test("retryFailedRead looks the song up again", () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.listen(_lookup("Deviancy"), (_, __) {});
    await expectLater(
        container.read(_lookup("Deviancy").future), throwsException);

    final result = await retryFailedRead(
      read: () => container.read(_lookup("Deviancy").future),
      invalidate: () => container.invalidate(_lookup("Deviancy")),
      name: "Deviancy",
    );
    expect(result, "audio for Deviancy");
    expect(lookups, 2);
  });

  test("a song that works is not looked up twice", () async {
    lookups = 1; // first lookup succeeds
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final result = await retryFailedRead(
      read: () => container.read(_lookup("Baby").future),
      invalidate: () => container.invalidate(_lookup("Baby")),
      name: "Baby",
    );
    expect(result, "audio for Baby");
    expect(lookups, 2);
  });
}

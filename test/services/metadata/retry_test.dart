import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotube/services/logger/logger.dart';
import 'package:spotube/services/metadata/retry.dart';

DioException _status(int code, {String? retryAfter}) {
  final options = RequestOptions(path: "/x");
  return DioException(
    requestOptions: options,
    type: DioExceptionType.badResponse,
    response: Response(
      requestOptions: options,
      statusCode: code,
      headers: Headers.fromMap({
        if (retryAfter != null) "retry-after": [retryAfter],
      }),
    ),
  );
}

/// A call that is refused with 429 (Retry-After 1 s) the first time and
/// answers the second time. [refused] completes at the first refusal.
FutureOr<dynamic> Function() _refusedOnce(Completer<void> refused) {
  var calls = 0;
  return () async {
    if (calls++ == 0) {
      refused.complete();
      throw _status(429, retryAfter: "1");
    }
    return "saved?";
  };
}

/// Lets the refusal be handled (hold set, retry scheduled) before going on.
Future<void> _settle() => Future.delayed(const Duration(milliseconds: 50));

Future<Duration> _time(Future<void> Function() f) async {
  final watch = Stopwatch()..start();
  await f();
  return watch.elapsed;
}

void main() {
  setUpAll(() => AppLogger.initialize(false));

  test("a 429 on one kind of call does not hold up search", () async {
    final gate = RequestGate(gap: Duration.zero);
    final refused = Completer<void>();
    final saved = runWithRetry(gate, "isSavedPlaylist", _refusedOnce(refused));
    await refused.future;
    await _settle();

    final took = await _time(() => runWithRetry(gate, "search", () => "found"));
    expect(took, lessThan(const Duration(milliseconds: 300)));
    expect(await saved, "saved?");
  });

  test("calls waiting to retry do not use up the slots", () async {
    // Phone, 16:02:18-20: three isSavedPlaylist calls were waiting 59 s each.
    final gate = RequestGate(gap: Duration.zero, maxConcurrent: 3);
    final waiting = <Future>[];
    for (var i = 0; i < 3; i++) {
      final refused = Completer<void>();
      waiting.add(runWithRetry(gate, "isSavedPlaylist", _refusedOnce(refused)));
      await refused.future;
      await _settle();
    }

    final took = await _time(() => runWithRetry(gate, "search", () => "found"));
    expect(took, lessThan(const Duration(milliseconds: 300)));
    expect(await Future.wait(waiting), ["saved?", "saved?", "saved?"]);
  });

  test("the same kind of call still waits out Spotify's Retry-After", () async {
    final gate = RequestGate(gap: Duration.zero);
    final refused = Completer<void>();
    final first = runWithRetry(gate, "isSavedPlaylist", _refusedOnce(refused));
    await refused.future;
    await _settle();

    final took = await _time(
      () => runWithRetry(gate, "isSavedPlaylist", () => "second"),
    );
    expect(took, greaterThan(const Duration(milliseconds: 900)));
    await first;
  });

  test("a 401 refreshes the login and retries once", () async {
    var refreshed = 0;
    var calls = 0;
    final result = await runWithRetry(
      RequestGate(gap: Duration.zero),
      "search",
      () => calls++ == 0 ? throw _status(401) : "found",
      refreshCredentials: () async => refreshed++,
    );
    expect(result, "found");
    expect(refreshed, 1);
  });

  test("other errors come straight through and free their slot", () async {
    final gate = RequestGate(gap: Duration.zero, maxConcurrent: 1);
    await expectLater(
      runWithRetry(gate, "search", () => throw _status(404)),
      throwsA(isA<DioException>()),
    );
    final took = await _time(() => runWithRetry(gate, "search", () => "ok"));
    expect(took, lessThan(const Duration(milliseconds: 300)));
  });
}

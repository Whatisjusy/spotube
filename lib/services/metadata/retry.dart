import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:hetu_script/values.dart';
import 'package:spotube/services/logger/logger.dart';

/// Retries plugin calls that fail for transient reasons, so a single network
/// hiccup does not surface as an error box.
///
/// - 401 (expired login): ask the plugin to refresh its credentials, retry once.
/// - 429 (rate limited) / 5xx: wait (Retry-After or backoff) and retry.
///   A 429 also pauses every other call of the same kind for that long.
/// - Connection errors and timeouts: wait briefly and retry.
/// Anything else is thrown straight through.
/// Paces plugin calls so the app never fires a burst at Spotify.
///
/// At most [maxConcurrent] calls run at once, each start is spaced by [gap],
/// and a 429 puts calls of that kind on hold for the server's Retry-After.
///
/// The hold used to cover every call. On the phone (2026-10-20) all 19 of
/// Spotify's 429s were for `isSavedPlaylist`, with Retry-After up to 59 s,
/// three times in a row, so search and every page load stood still for
/// three minutes because of one background check that was never refused
/// anywhere else.
@visibleForTesting
class RequestGate {
  final int maxConcurrent;
  final Duration gap;
  int _active = 0;
  DateTime _nextStart = DateTime.now();
  final _cooldowns = <String, DateTime>{};
  final _waiters = <Completer<void>>[];

  RequestGate({
    this.maxConcurrent = 3,
    this.gap = const Duration(milliseconds: 120),
  });

  /// Waits out a hold on [key] first, without taking a slot, so calls on hold
  /// never keep other calls from running.
  Future<void> acquire([String? key]) async {
    final until = key == null ? null : _cooldowns[key];
    if (until != null) {
      final hold = until.difference(DateTime.now());
      if (hold > Duration.zero) await Future.delayed(hold);
    }

    if (_active >= maxConcurrent) {
      final c = Completer<void>();
      _waiters.add(c);
      await c.future;
    }
    _active++;

    final now = DateTime.now();
    final startAt = _nextStart.isAfter(now) ? _nextStart : now;
    _nextStart = startAt.add(gap);
    final wait = startAt.difference(now);
    if (wait > Duration.zero) await Future.delayed(wait);
  }

  void release() {
    _active--;
    if (_waiters.isNotEmpty) _waiters.removeAt(0).complete();
  }

  void cooldown(Duration d, String key) {
    final until = DateTime.now().add(d);
    final current = _cooldowns[key];
    if (current == null || until.isAfter(current)) _cooldowns[key] = until;
  }
}

/// The retry loop behind [HTInstanceRetry.invokeWithRetry], separate from
/// the plugin interpreter so it can be tested.
///
/// [timeout], when given, limits [call]'s own execution time. It starts only
/// after the call has a slot in the gate, so time spent queued behind other
/// calls does not count. A timeout is thrown as [TimeoutException] and is
/// not retried.
@visibleForTesting
Future<dynamic> runWithRetry(
  RequestGate gate,
  String funcName,
  FutureOr<dynamic> Function() call, {
  Duration? timeout,
  Future<void> Function()? refreshCredentials,
  int maxAttempts = 4,
}) async {
  var attempt = 0;
  while (true) {
    attempt++;
    final queued = Stopwatch()..start();
    await gate.acquire(funcName);
    if (queued.elapsedMilliseconds > 1000) {
      AppLogger.log.i(
        "Plugin call '$funcName' waited ${queued.elapsedMilliseconds} ms "
        "for a slot",
      );
    }
    Duration? retryIn;
    try {
      final result = call();
      if (result is! Future) return result;
      return await (timeout == null ? result : result.timeout(timeout));
    } catch (e) {
      final delay = _retryDelay(e, attempt);
      if (_statusCode(e) == 429 && delay != null) gate.cooldown(delay, funcName);
      if (delay == null || attempt >= maxAttempts) rethrow;

      AppLogger.log.w(
        "Plugin call '$funcName' failed (attempt $attempt), "
        "retrying in ${delay.inMilliseconds}ms: $e",
      );

      if (_statusCode(e) == 401) await refreshCredentials?.call();
      retryIn = delay;
    } finally {
      gate.release();
    }
    // Wait for the retry without holding a slot. Holding it (as before) let
    // three calls waiting 59 s each block every other call.
    await Future.delayed(retryIn);
  }
}

int? _statusCode(Object e) =>
    e is DioException ? e.response?.statusCode : null;

Duration? _retryDelay(Object e, int attempt) {
  final backoff = Duration(seconds: 1 << (attempt - 1)); // 1s, 2s, 4s

  if (e is DioException) {
    final status = e.response?.statusCode;
    if (status == 401) {
      return attempt == 1 ? Duration.zero : null;
    }
    if (status == 429) {
      final retryAfter = int.tryParse(
        e.response?.headers.value("retry-after") ?? "",
      );
      if (retryAfter != null) {
        return Duration(seconds: retryAfter.clamp(1, 60));
      }
      return backoff * 2; // 2s, 4s, 8s
    }
    if (status != null && status >= 500) return backoff;

    return switch (e.type) {
      DioExceptionType.connectionError ||
      DioExceptionType.connectionTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.sendTimeout =>
        backoff,
      DioExceptionType.unknown
          when e.error is SocketException || e.error is HandshakeException =>
        backoff,
      _ => null,
    };
  }

  if (e is SocketException || e is HandshakeException) return backoff;
  return null;
}

extension HTInstanceRetry on HTInstance {
  static const _maxAttempts = 4;
  static Future<void>? _refreshInFlight;

  /// One gate per plugin (keyed by its interpreter), so a burst of audio
  /// source lookups (prefetching several songs) does not hold up Spotify
  /// metadata calls, and the other way round.
  static final _gates = Expando<RequestGate>("plugin request gates");
  RequestGate get _gate => _gates[interpreter] ??= RequestGate();

  /// See [runWithRetry].
  Future<dynamic> invokeWithRetry(
    String funcName, {
    List<dynamic> positionalArgs = const [],
    Map<String, dynamic> namedArgs = const {},
    Duration? timeout,
  }) {
    return runWithRetry(
      _gate,
      funcName,
      () => invoke(
        funcName,
        positionalArgs: positionalArgs,
        namedArgs: namedArgs,
      ),
      timeout: timeout,
      refreshCredentials: _refreshCredentials,
      maxAttempts: _maxAttempts,
    );
  }

  /// Asks the metadata plugin to renew its login. Concurrent failures share
  /// one refresh. Plugins without auth simply ignore this.
  Future<void> _refreshCredentials() {
    return _refreshInFlight ??= () async {
      try {
        final plugin = interpreter.fetch("metadataPlugin");
        if (plugin is! HTInstance) return;
        final auth = plugin.memberGet("auth");
        if (auth is! HTInstance) return;
        final result = auth.invoke("refreshCredentials");
        if (result is Future) await result;
      } catch (e) {
        AppLogger.log.w("Credential refresh failed: $e");
      } finally {
        _refreshInFlight = null;
      }
    }();
  }
}

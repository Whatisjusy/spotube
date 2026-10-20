import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:hetu_script/values.dart';
import 'package:spotube/services/logger/logger.dart';

/// Retries plugin calls that fail for transient reasons, so a single network
/// hiccup does not surface as an error box.
///
/// - 401 (expired login): ask the plugin to refresh its credentials, retry once.
/// - 429 (rate limited) / 5xx: wait (Retry-After or backoff) and retry.
///   A 429 also pauses every other call for that long.
/// - Connection errors and timeouts: wait briefly and retry.
/// Anything else is thrown straight through.
/// Paces plugin calls so the app never fires a burst at Spotify.
///
/// At most [maxConcurrent] calls run at once, each start is spaced by [gap],
/// and a 429 puts everyone on hold for the server's Retry-After.
class _RequestGate {
  final int maxConcurrent;
  final Duration gap;
  int _active = 0;
  DateTime _nextStart = DateTime.now();
  DateTime? _cooldownUntil;
  final _waiters = <Completer<void>>[];

  _RequestGate()
      : maxConcurrent = 3,
        gap = const Duration(milliseconds: 120);

  Future<void> acquire() async {
    if (_active >= maxConcurrent) {
      final c = Completer<void>();
      _waiters.add(c);
      await c.future;
    }
    _active++;

    final now = DateTime.now();
    var startAt = _nextStart.isAfter(now) ? _nextStart : now;
    if (_cooldownUntil != null && _cooldownUntil!.isAfter(startAt)) {
      startAt = _cooldownUntil!;
    }
    _nextStart = startAt.add(gap);
    final wait = startAt.difference(now);
    if (wait > Duration.zero) await Future.delayed(wait);
  }

  void release() {
    _active--;
    if (_waiters.isNotEmpty) _waiters.removeAt(0).complete();
  }

  void cooldown(Duration d) {
    final until = DateTime.now().add(d);
    if (_cooldownUntil == null || until.isAfter(_cooldownUntil!)) {
      _cooldownUntil = until;
    }
  }
}

extension HTInstanceRetry on HTInstance {
  static const _maxAttempts = 4;
  static Future<void>? _refreshInFlight;

  /// One gate per plugin (keyed by its interpreter), so a burst of audio
  /// source lookups (prefetching several songs) does not hold up Spotify
  /// metadata calls, and the other way round.
  static final _gates = Expando<_RequestGate>("plugin request gates");
  _RequestGate get _gate => _gates[interpreter] ??= _RequestGate();

  /// [timeout], when given, limits the plugin's own execution time. It
  /// starts only after the call has a slot in the gate, so time spent
  /// queued behind other calls does not count. A timeout is thrown as
  /// [TimeoutException] and is not retried.
  Future<dynamic> invokeWithRetry(
    String funcName, {
    List<dynamic> positionalArgs = const [],
    Map<String, dynamic> namedArgs = const {},
    Duration? timeout,
  }) async {
    var attempt = 0;
    while (true) {
      attempt++;
      final queued = Stopwatch()..start();
      await _gate.acquire();
      if (queued.elapsedMilliseconds > 1000) {
        AppLogger.log.d(
          "Plugin call '$funcName' waited ${queued.elapsedMilliseconds} ms "
          "for a slot",
        );
      }
      try {
        final result = invoke(
          funcName,
          positionalArgs: positionalArgs,
          namedArgs: namedArgs,
        );
        if (result is! Future) return result;
        return await (timeout == null ? result : result.timeout(timeout));
      } catch (e) {
        final delay = _retryDelay(e, attempt);
        if (_statusCode(e) == 429 && delay != null) _gate.cooldown(delay);
        if (delay == null || attempt >= _maxAttempts) rethrow;

        AppLogger.log.w(
          "Plugin call '$funcName' failed (attempt $attempt), "
          "retrying in ${delay.inMilliseconds}ms: $e",
        );

        if (_statusCode(e) == 401) {
          await _refreshCredentials();
        }
        await Future.delayed(delay);
      } finally {
        _gate.release();
      }
    }
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

  static int? _statusCode(Object e) =>
      e is DioException ? e.response?.statusCode : null;

  static Duration? _retryDelay(Object e, int attempt) {
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
}

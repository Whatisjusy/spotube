import 'package:hetu_script/binding.dart';
import 'package:hetu_script/values.dart';
import 'package:hetu_std/http/http.dart' as hetu_http;
import 'package:spotube/services/metadata/retry.dart';

/// Sends persisted queries straight to Spotify's query server
/// (`api-partner.spotify.com/pathfinder`) through the Spotify plugin's own
/// logged-in client (`metadataPlugin.api.gqlClient`).
///
/// The Spotify plugin 0.2.2 sends a few calls to the old public API
/// (`api.spotify.com/v1`) instead, and Spotify refuses those with 429 nearly
/// every time (on the phone, 2026-10-20: `related` 12/12, `savedArtists` 9/9,
/// `isSavedPlaylist` 31 refusals), with Retry-After up to 59 s, so each one
/// spun for ~95 s of retries and then failed. Its query-server calls were
/// never refused. The queries used here are the ones the plugin's newer
/// Kotlin version uses for the same things.
class SpotifyGql {
  final HTInstance _endpoint;

  SpotifyGql._(this._endpoint);

  /// Null when the active plugin is not the Spotify one.
  static SpotifyGql? of(HTInstance endpoint) =>
      _client(endpoint) == null ? null : SpotifyGql._(endpoint);

  /// Fetched on every request, not kept: the plugin builds a new client on
  /// each login, so a retry after a 401 must pick up the new one.
  static hetu_http.HttpClient? _client(HTInstance endpoint) {
    try {
      final plugin = endpoint.interpreter.fetch("metadataPlugin");
      if (plugin is! HTInstance) return null;
      final api = plugin.memberGet("api");
      if (api is! HTInstance) return null;
      var client = api.memberGet("gqlClient");
      if (client is HTExternalInstance) client = client.externalObject;
      return client is hetu_http.HttpClient ? client : null;
    } catch (_) {
      return null;
    }
  }

  /// Runs through the plugin's gate and retries under [funcName], so it is
  /// paced and held with the plugin's own call of that name.
  Future<dynamic> query(
    String funcName, {
    required String operation,
    required String hash,
    required Map<String, dynamic> variables,
  }) async {
    final res = await _endpoint.runWithRetryFor(funcName, () {
      final client = _client(_endpoint);
      if (client == null) throw StateError("Spotify plugin client is gone");
      return client.post(
        "",
        data: {
          "variables": variables,
          "operationName": operation,
          "extensions": {
            "persistedQuery": {"version": 1, "sha256Hash": hash},
          },
        },
      );
    }) as hetu_http.HttpResponse;
    return res.data;
  }
}

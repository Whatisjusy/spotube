import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:spotube/services/youtube_engine/youtube_explode_engine.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

/// Diagnostic: which YouTube endpoints answer from this device's network.
///
/// Google sends some networks (shared mobile IPs) to its "unusual traffic"
/// page for the HTML search the engine uses. This asks each way of reaching
/// YouTube once and returns one line per probe: "ok", "BLOCKED" (sent to
/// google.com/sorry or a google_abuse redirect) or "FAILED <reason>".
Future<List<String>> probeYouTube({
  String query = "Daniel Allan Safe",
  String videoId = "B-1PuX6I3zw",
}) async {
  final dio = Dio(BaseOptions(
    followRedirects: false,
    validateStatus: (_) => true,
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 15),
  ));
  final results = <String>[];

  String verdict(Response res, bool Function(String body) ok) {
    final location = res.headers.value("location") ?? "";
    if (location.contains("google.com/sorry") ||
        location.contains("google_abuse")) {
      return "BLOCKED (${res.statusCode} to robot check)";
    }
    final body = res.data is String ? res.data as String : jsonEncode(res.data);
    if (res.statusCode == 200 && ok(body)) return "ok";
    return "FAILED status ${res.statusCode}";
  }

  Future<void> probe(String name, Future<String> Function() run) async {
    final watch = Stopwatch()..start();
    try {
      results.add("$name: ${await run()} (${watch.elapsedMilliseconds} ms)");
    } catch (e) {
      final reason = e.toString().split("\n").first;
      final blocked = reason.contains("google_abuse") ||
          reason.contains("google.com/sorry");
      results.add("$name: ${blocked ? "BLOCKED" : "FAILED"} "
          "${reason.substring(0, reason.length.clamp(0, 120))} "
          "(${watch.elapsedMilliseconds} ms)");
    }
  }

  await probe("html search (engine today)", () async {
    final res = await dio.get(
      "https://www.youtube.com/results",
      queryParameters: {"search_query": query},
      options: Options(responseType: ResponseType.plain),
    );
    return verdict(res, (b) => b.contains("videoRenderer"));
  });

  await probe("innertube web search", () async {
    final res = await dio.post(
      "https://www.youtube.com/youtubei/v1/search?prettyPrint=false",
      data: {
        "context": {
          "client": {
            "clientName": "WEB",
            "clientVersion": "2.20260708.00.00",
            "hl": "en",
          },
        },
        "query": query,
      },
      options: Options(responseType: ResponseType.plain),
    );
    return verdict(res, (b) => b.contains("videoRenderer"));
  });

  await probe("youtube music songs search", () async {
    final res = await dio.post(
      "https://music.youtube.com/youtubei/v1/search?prettyPrint=false",
      data: {
        "context": {
          "client": {
            "clientName": "WEB_REMIX",
            "clientVersion": "1.20260707.12.00",
            "hl": "en",
          },
        },
        "query": query,
        "params": "EgWKAQIIAWoKEAoQAxAEEAkQBQ==",
      },
      options: Options(responseType: ResponseType.plain),
    );
    return verdict(res, (b) => b.contains("musicResponsiveListItemRenderer"));
  });

  await probe("watch page", () async {
    final res = await dio.get(
      "https://www.youtube.com/watch",
      queryParameters: {"v": videoId},
      options: Options(responseType: ResponseType.plain),
    );
    return verdict(res, (b) => b.contains("ytInitialPlayerResponse"));
  });

  await probe("visionOS stream link (playback today)", () async {
    final yt = YoutubeExplode();
    try {
      final manifest = await yt.videos.streamsClient.getManifest(
        videoId,
        requireWatchPage: true,
        ytClients: [visionOsClient],
      );
      return manifest.audioOnly.isEmpty ? "FAILED no audio" : "ok";
    } finally {
      yt.close();
    }
  });

  dio.close();
  return results;
}

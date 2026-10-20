@Tags(["live"])
library;

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotube/services/youtube_engine/youtube_explode_engine.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

/// Live: the engine's stream URLs must serve the WHOLE file to the request
/// the playback server makes (HEAD, then GET with "range: bytes=0-"), not
/// just the first ~1 MB.
void main() {
  final userAgent = (YoutubeApiClient.android.payload["context"]
      as Map)["client"]["userAgent"] as String;

  for (final id in ["B-1PuX6I3zw", "Ng5zo2A-us4", "CW0T5A7M6As"]) {
    test("$id plays to the end", () async {
      final engine = YouTubeExplodeEngine();
      final manifest = await engine.getStreamManifest(id);
      final stream = manifest.audioOnly.withHighestBitrate();
      final url = stream.url.toString();
      expect(Uri.parse(url).queryParameters["c"], "VISIONOS");

      final dio = Dio();
      final headers = {
        "accept": "*/*",
        "range": "bytes=0-",
        "icy-metadata": "1",
        "user-agent": userAgent,
        "host": Uri.parse(url).host,
      };
      final head = await dio.head(url, options: Options(headers: headers));
      expect(head.statusCode, 206);

      final res = await dio.get<ResponseBody>(
        url,
        options: Options(headers: headers, responseType: ResponseType.stream),
      );
      var bytes = 0;
      await for (final chunk in res.data!.stream) {
        bytes += chunk.length;
      }
      expect(bytes, stream.size.totalBytes);

      final mid = stream.size.totalBytes ~/ 2;
      final seek = await dio.get<List<int>>(
        url,
        options: Options(
          headers: {...headers, "range": "bytes=$mid-${mid + 1023}"},
          responseType: ResponseType.bytes,
        ),
      );
      expect(seek.statusCode, 206);
    }, timeout: const Timeout(Duration(seconds: 90)));
  }
}

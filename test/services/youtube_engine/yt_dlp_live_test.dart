// Hits the network and needs the yt-dlp binary; run by hand:
//   fvm flutter test test/services/youtube_engine/yt_dlp_live_test.dart --run-skipped
import 'package:flutter_test/flutter_test.dart';
import 'package:spotube/services/youtube_engine/yt_dlp_engine.dart';
import 'package:yt_dlp_dart/yt_dlp_dart.dart';

void main() {
  test(
    "yt-dlp songs and videos searches both parse",
    () async {
      await YtDlp.instance.setBinaryLocation("/opt/homebrew/bin/yt-dlp");
      final engine = YtDlpEngine();

      final songs = await engine.searchSongs("Jersey U&I");
      expect(songs, isNotEmpty);
      expect(songs.first.title, "U&I");

      final videos = await engine.searchVideos("Jersey U&I");
      expect(videos, isNotEmpty);
      expect(videos.first.author, isNotEmpty);
      expect(videos.first.duration, isNot(Duration.zero));
    },
    skip: "needs yt-dlp installed and network access",
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

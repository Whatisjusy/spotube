import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/services/network_cost.dart';
import 'package:spotube/services/sourced_track/sourced_track.dart';

SpotubeAudioSourceStreamObject stream(String container, double? bitrate) =>
    SpotubeAudioSourceStreamObject(
      url: "$container-$bitrate",
      container: container,
      type: container == "flac"
          ? SpotubeMediaCompressionType.lossless
          : SpotubeMediaCompressionType.lossy,
      bitrate: bitrate,
    );

void main() {
  group("dataSaverStream", () {
    test("Monochrome FLAC topped up with YouTube picks Opus ~130k", () {
      final pick = SourcedTrack.dataSaverStream([
        stream("flac", null),
        stream("webm", 50000),
        stream("webm", 135000),
        stream("mp4", 130000),
      ]);
      expect(pick?.url, "webm-135000.0");
    });

    test("AAC only: lowest bitrate from 112k up", () {
      final pick = SourcedTrack.dataSaverStream([
        stream("flac", null),
        stream("mp4", 96000),
        stream("mp4", 320000),
      ]);
      expect(pick?.url, "mp4-320000.0");
    });

    test("only low bitrates: the best of them", () {
      final pick = SourcedTrack.dataSaverStream([
        stream("webm", 50000),
        stream("webm", 70000),
      ]);
      expect(pick?.url, "webm-70000.0");
    });

    test("FLAC only: no data saver stream", () {
      expect(SourcedTrack.dataSaverStream([stream("flac", null)]), isNull);
    });
  });

  group("isMetered", () {
    test("mobile alone is metered", () {
      expect(NetworkCost.isMetered([ConnectivityResult.mobile]), isTrue);
    });
    test("Wi-Fi, or Wi-Fi with VPN, is not", () {
      expect(NetworkCost.isMetered([ConnectivityResult.wifi]), isFalse);
      expect(
        NetworkCost.isMetered(
          [ConnectivityResult.wifi, ConnectivityResult.mobile],
        ),
        isFalse,
      );
      expect(
        NetworkCost.isMetered([ConnectivityResult.vpn, ConnectivityResult.wifi]),
        isFalse,
      );
    });
    test("mobile with VPN is metered", () {
      expect(
        NetworkCost.isMetered(
          [ConnectivityResult.vpn, ConnectivityResult.mobile],
        ),
        isTrue,
      );
    });
  });
}

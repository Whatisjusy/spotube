import 'package:flutter_test/flutter_test.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/services/sourced_track/source_label.dart';

SpotubeAudioSourceStreamObject stream({
  required String container,
  required SpotubeMediaCompressionType type,
  String? codec,
  double? bitrate,
  int? bitDepth,
  double? sampleRate,
}) =>
    SpotubeAudioSourceStreamObject(
      url: "https://x",
      container: container,
      type: type,
      codec: codec,
      bitrate: bitrate,
      bitDepth: bitDepth,
      sampleRate: sampleRate,
    );

void main() {
  test("sourceLabel", () {
    expect(
      sourceLabel(stream(
        container: "flac", type: SpotubeMediaCompressionType.lossless,
        bitDepth: 24, sampleRate: 96000,
      )),
      "FLAC 24/96",
    );
    expect(
      sourceLabel(stream(
        container: "flac", type: SpotubeMediaCompressionType.lossless,
        bitDepth: 16, sampleRate: 44100,
      )),
      "FLAC 16/44.1",
    );
    expect(
      sourceLabel(stream(container: "flac", type: SpotubeMediaCompressionType.lossless)),
      "FLAC",
    );
    expect(
      sourceLabel(stream(
        container: "webm", type: SpotubeMediaCompressionType.lossy,
        codec: "opus", bitrate: 160000,
      )),
      "Opus 160k",
    );
    expect(
      sourceLabel(stream(
        container: "mp4", type: SpotubeMediaCompressionType.lossy,
        codec: "mp4a.40.2", bitrate: 128000,
      )),
      "AAC 128k",
    );
    expect(
      sourceLabel(stream(
        container: "mp4", type: SpotubeMediaCompressionType.lossy,
        codec: "aac", bitrate: 165000,
      )),
      "AAC 165k",
    );
  });

  test("looksLikeMusicVideo", () {
    expect(looksLikeMusicVideo("Jersey - U&I (Official Video)"), isTrue);
    expect(looksLikeMusicVideo("ero808 - POUR IT OUT (Official Music Video)"), isTrue);
    expect(looksLikeMusicVideo("U&I"), isFalse);
    expect(looksLikeMusicVideo("Jersey - U&I (Official Audio)"), isFalse);
  });
}

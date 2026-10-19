import 'package:spotube/models/metadata/metadata.dart';

/// Title words that mark a music video rather than the plain audio.
const musicVideoWords = [
  "official video",
  "music video",
  "official music video",
];

/// True when the matched title reads like a music video rather than audio.
bool looksLikeMusicVideo(String title) {
  final t = title.toLowerCase();
  return musicVideoWords.any(t.contains);
}

/// Short label for what is actually playing: "FLAC 24/96", "FLAC",
/// "Opus 160k", "AAC 128k".
String sourceLabel(SpotubeAudioSourceStreamObject s) {
  final container = s.container.toLowerCase();
  final codec = (s.codec ?? "").toLowerCase();

  if (s.type == SpotubeMediaCompressionType.lossless || container == "flac") {
    final name = container == "flac" ? "FLAC" : container.toUpperCase();
    if (s.bitDepth != null && s.sampleRate != null && s.sampleRate! > 0) {
      return "$name ${s.bitDepth}/${_kilohertz(s.sampleRate!)}";
    }
    return name;
  }

  final String codecName;
  if (codec.contains("opus") || (codec.isEmpty && container == "webm")) {
    codecName = "Opus";
  } else if (codec.contains("mp4a") ||
      codec.contains("aac") ||
      (codec.isEmpty && (container == "mp4" || container == "m4a"))) {
    codecName = "AAC";
  } else if (codec.contains("vorbis")) {
    codecName = "Vorbis";
  } else {
    codecName = (codec.isEmpty ? container : codec).toUpperCase();
  }

  if (s.bitrate != null && s.bitrate! > 0) {
    return "$codecName ${(s.bitrate! / 1000).round()}k";
  }
  return codecName;
}

String _kilohertz(double hertz) {
  final k = hertz / 1000;
  return k == k.roundToDouble() ? k.round().toString() : k.toStringAsFixed(1);
}

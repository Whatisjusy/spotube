import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:spotube/services/youtube_engine/youtube_engine.dart';
import 'package:spotube/utils/platform.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:yt_dlp_dart/yt_dlp_dart.dart';
// ignore: depend_on_referenced_packages
import 'package:http_parser/http_parser.dart';

class YtDlpEngine implements YouTubeEngine {
  StreamManifest _parseFormats(List formats, videoId) {
    final audioOnlyStreams = formats
        .where((f) => f["resolution"] == "audio only")
        .sorted((a, b) => a["quality"] > b["quality"] ? 1 : -1)
        .map((f) {
      final filesize = f["filesize"] ?? f["filesize_approx"];
      return AudioOnlyStreamInfo(
        VideoId(videoId),
        0,
        Uri.parse(f["url"]),
        StreamContainer.parse(
          f["container"]?.replaceAll("_dash", "").replaceAll("m4a", "mp4") ??
              (f["protocol"] == "m3u8_native" ? "m3u8" : "mp4"),
        ),
        filesize != null ? FileSize(filesize) : FileSize.unknown,
        Bitrate(
          (((f["abr"] ?? f["tbr"] ?? 0) * 1000) as num).toInt(),
        ),
        f["acodec"] ?? "aac",
        f["format_note"],
        [],
        MediaType.parse(
          "audio/${f["audio_ext"]}",
        ),
        null,
      );
    });

    return StreamManifest(audioOnlyStreams);
  }

  /// Stands in when a listing carries no channel id (YouTube Music search
  /// results in --flat-playlist mode have no channel, id or length).
  static const _unknownChannel = "UCxxxxxxxxxxxxxxxxxxxxxx";

  Video _parseInfo(Map<String, dynamic> info) {
    final publishDate = info["upload_date"] != null
        ? DateTime.fromMillisecondsSinceEpoch(
            int.parse(info["upload_date"]) * 1000,
          )
        : DateTime.now();
    final channelId = info["channel_id"] as String?;
    return Video(
      VideoId(info["id"]),
      info["title"] ?? "",
      info["channel"] ?? info["uploader"] ?? info["artist"] ?? "",
      ChannelId(
        channelId != null && ChannelId.validateChannelId(channelId)
            ? channelId
            : _unknownChannel,
      ),
      publishDate,
      info["upload_date"] as String? ?? DateTime.now().toString(),
      publishDate,
      info["description"] ?? "",
      Duration(seconds: (info["duration"] as num?)?.toInt() ?? 0),
      ThumbnailSet(info["id"]),
      info["tags"]?.cast<String>() ?? <String>[],
      Engagement(
        (info["view_count"] as num?)?.toInt() ?? 0,
        (info["like_count"] as num?)?.toInt(),
        null,
      ),
      info["is_live"] ?? false,
    );
  }

  static bool get isAvailableForPlatform => kIsDesktop;

  /// Places package managers put yt-dlp that a Dock-launched Mac app (bare
  /// system PATH) or a Linux desktop app cannot see.
  static List<String> get knownLocations {
    final home = Platform.environment["HOME"] ?? "";
    return [
      "/opt/homebrew/bin/yt-dlp",
      "/usr/local/bin/yt-dlp",
      if (home.isNotEmpty) "$home/.local/bin/yt-dlp",
      "/usr/bin/yt-dlp",
    ];
  }

  /// The yt-dlp binary to use: "yt-dlp" when it is in PATH, else the first
  /// known location that exists, else null.
  static Future<String?> findBinary() async {
    if (!isAvailableForPlatform) return null;
    if (await YtDlp.instance.checkAvailableInPath()) return "yt-dlp";
    for (final location in knownLocations) {
      if (await File(location).exists()) return location;
    }
    return null;
  }

  static Future<bool> isInstalled() async {
    return await findBinary() != null;
  }

  @override
  Future<StreamManifest> getStreamManifest(String videoId) async {
    final formats = await YtDlp.instance.extractInfo(
      "https://www.youtube.com/watch?v=$videoId",
      formatSpecifiers: "%(formats)j",
      extraArgs: [
        "--no-check-certificate",
        "--geo-bypass",
        "--quiet",
        "--ignore-errors"
      ],
    ) as List;

    return _parseFormats(formats, videoId);
  }

  @override
  Future<Video> getVideo(String videoId) async {
    final info = await YtDlp.instance.extractInfo(
      "https://www.youtube.com/watch?v=$videoId",
      formatSpecifiers: "%()j",
      extraArgs: [
        "--skip-download",
        "--no-check-certificate",
        "--geo-bypass",
        "--quiet",
        "--ignore-errors",
      ],
    ) as Map<String, dynamic>;

    return _parseInfo(info);
  }

  @override
  Future<(Video, StreamManifest)> getVideoWithStreamInfo(String videoId) async {
    final info = await YtDlp.instance.extractInfo(
      "https://www.youtube.com/watch?v=$videoId",
      formatSpecifiers: "%()j",
      extraArgs: [
        "--no-check-certificate",
        "--geo-bypass",
        "--quiet",
        "--ignore-errors",
      ],
    ) as Map<String, dynamic>;

    return (_parseInfo(info), _parseFormats(info["formats"], videoId));
  }

  @override
  Future<List<Video>> searchVideos(String query) async {
    final stdout = await YtDlp.instance.extractInfoString(
      "ytsearch10:$query",
      formatSpecifiers: "%()j",
      extraArgs: [
        "--skip-download",
        "--no-check-certificate",
        "--geo-bypass",
        "--quiet",
        "--ignore-errors",
        "--flat-playlist",
        "--no-playlist",
      ],
    );

    final json = jsonDecode(
      "[${stdout.split("\n").where((s) => s.trim().isNotEmpty).join(",")}]",
    ) as List;

    return json.map((e) => _parseInfo(e)).toList();
  }

  /// YouTube Music "Songs" search is not used on yt-dlp. A flat listing of
  /// the Songs tab carries only id and title (no channel, no length), so the
  /// clean-audio ranking cannot score those results and they never beat a
  /// plain-search lyric video of the right length, while the extra process
  /// cost 1.5 s of CPU per lookup under prefetch load (measured
  /// 2026-10-20). The plain search below carries channel and length.
  @override
  Future<List<Video>> searchSongs(String query) async => const [];

  @override
  void dispose() {}
}

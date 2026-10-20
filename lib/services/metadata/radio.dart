import 'package:collection/collection.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/services/logger/logger.dart';
import 'package:spotube/services/metadata/metadata.dart';

/// Songs like [track], for endless playback when the queue runs out.
///
/// The same idea as the Spotify plugin's `track.radio` (Spotify's
/// "<song> Radio" playlist), done through the app's own search and playlist
/// calls. The plugin's version never worked on the phone: it crashed on all
/// 34 tries on 2026-10-20 (track.ht:33, an empty entry in the radio
/// playlist), so the music just stopped at the end of every queue. When
/// there is no radio playlist, or it cannot be read, the first artist's top
/// songs are used instead, so playback still carries on.
Future<List<SpotubeFullTrackObject>> songsLike(
  SpotubeTrackObject track, {
  required Future<List<SpotubeSimplePlaylistObject>> Function(String query)
      searchPlaylists,
  required Future<List<SpotubeFullTrackObject>> Function(String playlistId)
      playlistTracks,
  required Future<List<SpotubeFullTrackObject>> Function(String artistId)
      artistTopTracks,
}) async {
  final radioName = "${track.name} Radio";
  try {
    final playlists = await searchPlaylists(radioName);
    final radio = playlists.firstWhereOrNull(
      (p) => p.name.toLowerCase() == radioName.toLowerCase(),
    );
    if (radio != null) {
      final tracks = await playlistTracks(radio.id);
      if (tracks.isNotEmpty) {
        AppLogger.log.i("Endless playback: ${tracks.length} songs from "
            "\"${radio.name}\"");
        return tracks;
      }
    }
    AppLogger.log.i("Endless playback: no \"$radioName\" playlist");
  } catch (e) {
    AppLogger.log.w("Endless playback: \"$radioName\" failed: "
        "${"$e".split("\n").first}");
  }

  final artist = track.artists.firstOrNull;
  if (artist == null) return [];
  try {
    final tracks = await artistTopTracks(artist.id);
    AppLogger.log.i("Endless playback: ${tracks.length} top songs of "
        "${artist.name} instead");
    return tracks;
  } catch (e) {
    AppLogger.log.w("Endless playback: ${artist.name}'s top songs failed: "
        "${"$e".split("\n").first}");
    return [];
  }
}

/// [songsLike] through [plugin]'s endpoints.
Future<List<SpotubeFullTrackObject>> pluginSongsLike(
  MetadataPlugin plugin,
  SpotubeTrackObject track,
) {
  return songsLike(
    track,
    searchPlaylists: (query) async =>
        (await plugin.search.playlists(query, limit: 20)).items,
    playlistTracks: (id) async =>
        (await plugin.playlist.tracks(id, offset: 0, limit: 50)).items,
    artistTopTracks: (id) async =>
        (await plugin.artist.topTracks(id, offset: 0, limit: 20)).items,
  );
}

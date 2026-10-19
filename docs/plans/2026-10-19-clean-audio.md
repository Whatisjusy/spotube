# Clean audio plan

Goal: every song plays the studio master. Lossless FLAC when it exists,
otherwise YouTube's label-provided audio (Topic / Official Audio), never a
music video. All logic lives in the app, so it works whichever plugin answers.

Decided 2026-10-19. Status key: [ ] todo, [~] in progress, [x] done.

## Facts this plan rests on (verified 2026-10-19)

- Only one audio-source plugin can be selected at a time. "Lossless Sources"
  1.3.1 is installed but not selected; "YouTube Audio" 1.0.0 is selected.
- Lossless Sources tries Monochrome (FLAC, matched by ISRC), then hifi-api
  (all public instances blocked), then YouTube via the app's own engine.
- The app keeps only streams whose container matches the chosen format
  (`getStreamOfQuality` in `lib/services/sourced_track/sourced_track.dart`).
  With FLAC chosen, a YouTube-only song has no FLAC stream and is skipped.
  `.reduce` on the empty list throws.
- `fetchSiblings` in the same file skips ranking for English titles, so the
  first YouTube search result wins. The official regex scores "Official Video"
  the same as "Official Audio".
- The YouTube Audio plugin searches by ISRC first and trusts any result.
- The selected YouTube engine is NewPipe. Its Dart package exposes
  `SearchContentFilters.musicSongs` (YouTube Music "Songs" tab).
- Picks are cached per track in `source_match_table` (210 rows today:
  30 music videos, 36 official audio/Topic, 9 lyric videos).
- The Spotify track object carries `durationMs`; match objects carry
  `duration` in seconds, so length can be compared.

## Phases

### Phase 1. Format fallback (the "switch fast" piece)

File: `lib/services/sourced_track/sourced_track.dart`, `getStreamOfQuality`.

- [x] If no stream matches the chosen container, fall back in this order:
      flac, webm (Opus), mp4 (AAC). Pick the closest bitrate within the
      fallback container.
- [x] Never call `.reduce` on an empty list. Return null only when there are
      no streams at all.
- [x] Log one line per fallback: track name, wanted format, got format.
- [x] Verify: set format to flac, play a song that is YouTube-only (a fan
      remix or obscure track). It must play, and the log must show the
      fallback line.

Estimate: 30 min.

Done 2026-10-19. Verified in the debug build: "Run Away (feat. Car)" matched
hifi-api, which only had AAC; log showed
`Format fallback for "Run Away (feat. Car)": wanted flac, got mp4 aac 165k`
and the song played (HTTP 206). Before this change it would have thrown.
Also: the stream server's content-type / cache filename and the download
filename now follow the container actually picked, not the chosen preset.

### Phase 2. Switch to Lossless Sources, FLAC default

- [x] Settings: select Lossless Sources as the audio source.
- [x] Settings: streaming format flac, highest quality.
- [x] Make flac the app default when the selected plugin offers it, so a
      reinstall does not silently drop back to mp4. (`quality_presets.dart`,
      `selectedStreamingContainerIndex`.)
- [x] Verify: play 5 mainstream songs. Log must show a Monochrome URL and
      the stream must report container flac. Play 1 obscure song, it must
      fall through to YouTube via Phase 1.

Estimate: 20 min.

Done 2026-10-19. Plugin switched in `plugins_table` (DB backed up first as
`db.sqlite.bak-2026-10-19-before-lossless-switch`). 9 of 10 songs matched
Monochrome / hifi-api with ~50 MB files for a 4.5 min song (FLAC size; AAC
would be ~5 MB). First-run default is now the first lossless preset at its
best quality. The 10th song fell back to AAC via Phase 1.

### Phase 3. Clean-audio ranking for YouTube results

File: `lib/services/sourced_track/sourced_track.dart`.

- [x] Always rank. Remove the English-only skip in `fetchSiblings`.
- [x] Drop implausible results first: title must contain the song name (or
      the reverse) after stripping punctuation and case. This guards the
      ISRC search, which returns random videos for unknown codes.
- [x] Score. Suggested weights, tune after testing:
      - channel ends with " - Topic": +6
      - title has "official audio", "audio", "lyric", "lyrics", "visualizer":
        +3
      - title contains song name: +3; contains an artist name: +1 each
      - channel matches an artist name: +2
      - length within 2 s of Spotify's: +3; within 5 s: +1; off by more
        than 10 s: -4
      - title has "official video", "music video", "official music video":
        -3
      - title has "live", "remix", "cover", "slowed", "sped up", "8d",
        "nightcore", "reaction", "karaoke", "instrumental" (when the Spotify
        title does not): -5 each
- [x] Keep the current regex only as a fallback for plugins that do not
      send a channel name.
- [x] Verify: for 10 songs that today play a music video (query
      `source_match_table` for "Official Video"), clear their cache row,
      replay, and check the new pick is Topic or Official Audio.

Estimate: 1 h.

Done 2026-10-19. Only YouTube results (link contains youtube.com/youtu.be or
id starts with `youtube:`) are filtered and scored; Monochrome / hifi-api
matches keep the plugin's order and stay first, so FLAC still wins. Match
lengths arrive in mixed units (YouTube Audio: seconds, Monochrome: ms) and
are guessed from size (`matchSeconds`). Verified with 7 unit tests in
`test/services/sourced_track/rank_results_test.dart` (Topic > lyrics >
official video > live; bad-ISRC junk dropped; FLAC matches untouched;
"Remix" in the Spotify title not penalised; non-English titles ranked).
Live ranking output logs as `Ranked YouTube results for "<song>": [score] title (channel) | ...`.
Not yet tuned against real YouTube-fallback plays; see Phase 9.

### Phase 4. Search YouTube Music "Songs" instead of plain YouTube

Files: `lib/services/youtube_engine/newpipe_engine.dart`,
`lib/services/youtube_engine/youtube_engine.dart`, and the plugin bridge in
`lib/services/metadata/metadata.dart`.

- [x] Add `searchSongs(query)` to the engine interface. NewPipe: use
      `SearchContentFilters.musicSongs`. yt-dlp: `https://music.youtube.com/search?q=<q>#songs`.
      youtube_explode: no songs tab, fall back to `searchVideos`.
- [x] In the bridge, try `searchSongs` first; if it returns nothing, use
      `searchVideos`. Plugins keep calling the same `search` and get songs
      first without changing.
- [x] Phase 3 ranking still runs on the result, as the safety net.
- [x] Verify: log the channel names of the top 3 results for 10 songs. They
      should be mostly " - Topic" or the artist's own channel.

Risk: the NewPipe binary on macOS may not support the music filter. Test
with one query before building further. If it fails, keep Phase 3 only.

Estimate: 1.5 h.

Done 2026-10-19. Risk test passed first: the NewPipe CLI on this Mac answers
`--content-filters music_songs` ("Jersey U&I" -> "U&I" by Jersey from
music.youtube.com, where the plain video search led with the Official
Video). Note: Songs results carry the artist name as uploader, not
"<artist> - Topic", so the Phase 3 Topic bonus does not fire for them; the
artist-channel bonus does. The bridge (`searchYouTubeCleanFirst` in
`youtube_engine.dart`) runs songs and videos searches in parallel, returns
songs first then unseen videos, and survives either search failing. yt-dlp
uses the music.youtube.com search URL; youtube_explode falls back to videos.
Verified with 3 fake-engine tests. Live channel-name check deferred: every
song played today matched Monochrome, so no YouTube pick was saved yet.

### Phase 5. Speed guard

File: `lib/services/sourced_track/sourced_track.dart`, `fetchFromTrack`.

- [x] Wrap the plugin `matches` call in a 4 s timeout. On timeout, fall
      back to the YouTube-only path (Phase 3 ranking on a direct engine
      search) so the song still starts.
- [x] Wrap `streams` in a 4 s timeout the same way.
- [ ] Verify: block monochrome's host in /etc/hosts, play a song, it must
      start within about 5 s from YouTube. Remove the block afterwards.

Estimate: 30 min.

Code done 2026-10-19 (`audioSourceTimeout`, `streamsWithFallback`,
`youtubeFallbackMatches` in `sourced_track.dart`). On a `matches` timeout the
app searches YouTube itself (songs first, Phase 3 ranking) and does NOT save
the pick, so the plugin gets another chance next play. On a `streams`
timeout it streams the same video for a YouTube match, or the best YouTube
result for a Monochrome/hifi match, leaving the saved match alone. A plugin
error on a YouTube match also falls through to the engine; an error on a
non-YouTube match still surfaces. Elapsed ms for every plugin call is logged
at debug level to tune the 4 s. Verified with 5 unit tests (16 total).
The /etc/hosts live test is NOT done: it needs sudo, and relaunching the
debug app would kill the instance another session is running.

### Phase 6. Prefer webm (Opus) over mp4 on YouTube

- [x] In the Phase 1 fallback order, webm before mp4 (already listed).
- [x] Verify mpv on macOS plays the webm stream (it should, media_kit ships
      ffmpeg). Play one YouTube-only song and confirm the log shows webm.

Estimate: 10 min. Folded into Phase 1. Note: in the one fallback seen so far
the plugin offered only mp4 (hifi-api AAC), so webm was not exercised.

### Phase 7. Now Playing source tag

Files: `lib/modules/player/player_track_details.dart` (or
`player_controls.dart`), reading the active `SourcedTrack`.

- [ ] Small pill next to the title: "FLAC 24/96", "FLAC", "Opus 160k",
      "AAC 128k". Red tint if the matched title looks like a music video.
- [ ] Tap the pill to open the existing `sibling_tracks_sheet.dart`.
- [ ] Verify: play a FLAC song and a YouTube-only song, pill text changes.

Estimate: 45 min.

### Phase 8. One-tap "wrong version"

- [ ] Button in the same pill row: swap to the next-ranked sibling and save
      it (existing `swapWithSibling` already saves). Show a 2 s toast with
      the new title.
- [ ] Verify: tap it on a song, the audio changes and the choice survives an
      app restart.

Estimate: 30 min.

### Phase 9. Clear the old picks

- [ ] Back up `db.sqlite` first (copy next to it with a date suffix).
- [ ] `delete from source_match_table` so every song re-picks under the new
      rules. Do this after Phases 1 to 4 are in, not before.
- [ ] Tell the user the first play of each song will be a touch slower once.

Estimate: 5 min.

## Order

1 (fallback) -> 2 (switch plugin) -> 3 (ranking) -> 4 (songs search) ->
5 (timeouts) -> 7 (tag) -> 8 (button) -> 9 (clear cache). Phase 6 is inside 1.

Total: about 5 hours of work, spread over two sessions.

## Risks worth knowing

- Monochrome is one person's free service. If it dies, everything falls to
  YouTube clean audio. Phases 1, 3, 4 make that fallback good, so the app
  stays usable.
- YouTube changes its site often. NewPipe may break; the app already lets
  you switch engines in Settings > Playback.
- The debug build shares its database with the installed app. Phase 9
  clears picks for both.

# Spotube troubleshooting notes

The full stories behind one-line entries in `CLAUDE.md` (moved here 2026-10-21 to keep
`CLAUDE.md` short). Text is as it was written at the time.

## Spotify plugin 0.2.2 and retry.dart

- **Spotify data comes from a plugin, not this repo.** "Sonic Liberation / Spotify" 0.2.2, Hetu
  bytecode in the plugins folder above, source at
  https://github.com/sonic-liberation/spotube-plugin-spotify (tag `0.2.2`, `src/segments/*.ht`;
  `main` is now the Kotlin 6.0 version). It refreshes its token only on a timer and never checks
  expiry per request, so after the Mac sleeps every call 401s until the timer fires. The app-side
  answer is `lib/services/metadata/retry.dart` (`invokeWithRetry`: 401 -> ask plugin to
  `refreshCredentials` and retry once; 429/5xx -> backoff; connection errors -> retry). Every
  endpoint in `lib/services/metadata/endpoints/` goes through it. Since 2026-10-20 a 429 holds only
  calls of the same name (it used to hold every call: all 19 phone 429s were `isSavedPlaylist` with
  Retry-After up to 59 s, and search sat still for 3 minutes), and a call waiting to retry gives its
  slot back. Calls that queued over 1 s log `Plugin call '<name>' waited N ms for a slot` (info).
  Tests: `test/services/metadata/retry_test.dart` (they fail on the old behaviour; checked).
- **Old-API calls vs the query server (2026-10-21).** In the plugin's client
  (spotify-gql-client @32f3a26) only these use `api.spotify.com/v1`: `artist.related`, the details
  step of `user.savedAlbums`/`savedArtists` (`/v1/albums?ids=`, `/v1/artists?ids=`),
  `isPlaylistSaved`, and playlist `create`/`update`/`addTracks`/`removeTracks`/`follow`/`unfollow`.
  Every other call (search, browse, album, playlist and artist pages, tracks, library lists) goes to
  `api-partner.spotify.com/pathfinder`. On the phone every old-API read got 429 (related 12/12,
  savedArtists 9/9, isSavedPlaylist 31), Retry-After up to 59 s, so ~95 s of retries and then an error;
  live on the Mac the playlist check failed after 87-120 s three times out of three. Query-server calls
  were never refused. Fixes, each falling back to the plugin's own call on any error:
  - `SpotifyGql` (`lib/services/metadata/spotify_gql.dart`) posts persisted queries through the plugin's
    own logged-in client (`metadataPlugin.api.gqlClient`, fetched per attempt because a login replaces
    it), through the same gate/retries (`runWithRetryFor`).
  - Fans also like: `queryArtistRelated` (hash from the plugin's Kotlin `main`). Mac: 40 artists, <2 s.
    The section hides on failure instead of showing the 429 text. Log `Fans also like for <id>: N artists`.
  - Library Albums/Artists: the plugin's own `libraryV3` reply already holds names, pictures, album
    artists, type and date, so the app reads it directly and skips the refused details step
    (`libraryPageFromGql`). Mac: 129 artists / 62 albums, page in 0.2-0.6 s. Log `Library Artists: 20 of 129`.
  - Playlist saved check (`metadataPluginIsSavedPlaylistProvider`): looks the playlist up in the Library
    playlists list, paging the rest itself (0.3-1.1 s). `areEntitiesInLibrary` was tried: with the
    plugin's hash it returns only `{__typename: PlaylistResponseWrapper}` for playlists, no saved flag.
    Do not page via the shared provider's `fetchAll()` there: the provider watches that list, so it
    invalidated itself and its answer waited for the next frame (6 minutes in a hidden window).
  - Playlist edits and follow/unfollow: moved too, see the next entry.
- **Playlist edits off the old API (2026-10-21).** `lib/services/metadata/endpoints/playlist.dart`, each
  action falling back to the plugin's own call on any error. Requests copied from the plugin's Kotlin
  `PlaylistClient.kt`; tests `test/services/metadata/playlist_gql_test.dart`.
  - Where each goes: follow/unfollow/delete = `addItemsToRootlist` / `removeItemsFromRootlist`; add songs =
    `addToPlaylist` (to the end; the old API call put them at the top); remove songs = `removeFromPlaylist`
    after paging `fetchPlaylist` for the rows; create, rename/description and public =
    `SpotifyGql.post` to spclient (`/playlist/v2/playlist`, `.../<id>/changes`,
    `/playlist/v2/user/<user>/rootlist/changes`). Create = create + add to Library + set public.
  - Live on the Mac (throwaway playlist, run 3, 0 failures, Library 38 before and after): create 2.3 s, add
    0.9 s, remove 0.7 s (both copies of a song), rename 0.1 s, public 0.3 s, follow/unfollow/delete 0.2 s,
    each re-read from Spotify. Public checked in the rootlist entry (`attributes.public`) and on the profile
    (`user-profile-view/v3/profile/<user>/playlists`). Logs: `Created playlist`, `Updated playlist`,
    `Added N songs`, `Removed N rows`, `Playlist <id> added to / removed from Library`.
  - Still old API: the collaborative switch (no new request for it in the Kotlin source) and adding at a
    set position (no caller).
  - The plugin reports every playlist as public, so the edit dialog made private playlists public on any
    edit; it now sends only switches that were changed.
  - `ref.invalidate(isSavedPlaylist)` inside the saved-playlists notifier threw CircularDependencyError in
    debug builds (the saved check now watches that list) and undid a follow that worked; it goes through
    `ref.container` now. Release builds skip that check.
  - `spclient.wg.spotify.com/playlist/v2` accepts the plugin's bearer token alone (no client-token or
    cookie); a live create worked on the Mac. An absolute URL passed to the plugin's `gqlClient`
    overrides its base URL, so the same logged-in client can call it.
  - `removeFromPlaylist` takes row uids (`items[].uid` from `fetchPlaylist`), not track ids.
    `addToPlaylist`/`removeFromPlaylist`/`moveItemsInPlaylist` share one persisted-query hash in
    Spotify's own web player, so the Kotlin plugin's shared hash is right, but its `uids = trackIds` is wrong.
  - Plugin 0.2.2 `getPlaylist` crashes (RangeError on `images[0]`) for a playlist with no cover
    picture, e.g. a brand-new empty one. The playlist page survives only by falling back to the
    Library entry.
  - Upstream's playlist edit button passes the playlist's own songs to `PlaylistCreateDialog`, which
    re-added them all after `modify`. Hidden until now only because the old-API `addTracks` always
    failed with 429. The dialog now adds songs only when creating. Owner's edit through the dialog
    (2026-10-21, "What dreams feel like" description -> "save me", seen in Spotify's own app): one
    `Updated playlist`, no `Added N songs` line.
  - The playlist page shows the Library list's copy of name and description, so an edit that worked
    looked lost until a reload; `modify` now updates that copy too.
  - One owner edit got 400 from spclient before Spotify's reason was logged; the retry of the same kind
    worked. `SpotifyGql.post` now logs the reply body (`<path> refused: <status> <body>`); read it first
    if it happens again.
- **Launch queue (2026-10-21).** `metadataPluginAuthenticatedProvider` watched the whole plugin list
  and re-set its state on every token refresh, so it rebuilt 3 times per Mac launch (more on the phone
  after a 401 refresh) and each rebuild reloaded home sections, new releases, section items, profile and
  library lists; pages opened right after launch queued 2-4 s for the 3 slots. It now watches only
  "can this plugin log in" and sets state only when the value changes; sections/releases/section items
  await its `.future`. Counted live: 1 build each (was 3). `checkUpdate` (GitHub, 2-36 s) no longer uses
  the gate. Plugin calls over 2 s log `Plugin call '<name>' took N ms`.

## Testing a running debug build

- **Testing a running debug build:** `fvm flutter run` launched detached has no stdin, so no hot
  reload; kill the `Debug/Spotube Dev.app` process and relaunch. The app's local control server
  listens on a random port (`lsof -nP -iTCP -sTCP:LISTEN -a -p <pid>`); `GET /playback/toggle-playback`,
  `/playback/next`, `/playback/previous` drive playback for smoke tests, and
  `GET /stream/<trackId>` in the log proves which track the engine actually fetched.
  - The process is `Debug/Spotube Dev.app/Contents/MacOS/Spotube`; `pgrep -f "Spotube.app"` misses it.
    An older instance (yours or another session's) may already be running: `pgrep -fl "flutter
    run|Spotube Dev.app"` before launching, and only send commands to a pid that started after your
    launch. 2026-10-20: a `/playback/next` meant for a fresh build hit an old instance and moved the
    owner's saved queue (restored from a DB backup). Back up `audio_player_state_table` first.
  - Control port vs the Dart VM port: `curl /no-such-route-probe` returns `Route not found` only on
    the control server. To act while a song is still loading, wait for the engine's ESTABLISHED socket
    to it (`lsof -nP -iTCP:<port> -sTCP:ESTABLISHED -a -p <pid>`).
  - What the engine is really playing: `lsof -p <pid> | grep cached_tracks` (the open cache file).
    Compare with `current_index` in the DB, which is what the screen shows.

## YouTube on the phone

- **YouTube on the phone (tested 2026-10-20, live tests in `test/services/youtube_engine/`):** URLs from
  YouTubeExplode's android/ios clients are served only up to ~1 MB (403 past that, any range size),
  so every YouTube song failed with 403 at the server's HEAD/GET. All other built-in clients are refused
  ("Sign in to confirm you're not a bot"). `visionOsClient` (copied from yt-dlp's `visionos`) with
  `requireWatchPage: true` serves whole files; without the watch page it is refused too. yt-dlp on the
  Mac uses the same client (`c=VISIONOS` in its URLs). If YouTube breaks again, compare with
  `yt-dlp -v --print-traffic --extractor-args youtube:player_client=<client>`.

## Google's robot check

- **Google's robot check sticks to the engine's session, not the phone's network** (tested 2026-10-20 15:55):
  once searches get `Redirect limit exceeded ... google_abuse=GOOGLE_ABUSE_EXEMPTION`, every later search on
  that `YoutubeExplode` fails, so every song fails and the player skips through the queue. A fresh Dio
  request 4 s later passed, and the identical blocked search passed 20 s later after an app restart.
  `searchVideos` now asks the isolate for a new session (`resetSession`) and retries once (log `YouTube
  session sent to robot check; starting a new one`, then `worked on a new session` or `still blocked`).
  Fast skipping (13 songs in 20 s) is what triggered it. Proven live 16:00:03 and 16:00:25: both blocked
  searches worked on the new session within 0.7 s and the songs played. The 429 form
  (`RequestLimitExceededException`) is handled the same way; `TransientFailureException` ("Failed to
  retrieve initial data from SearchPage") is retried once after 0.7 s.

## YouTube ranking

- **YouTube ranking (`SourcedTrack.scoreMatch` / `rankResults`), fixed 2026-10-20 from owner reports:**
  (1) the +6 " - Topic" bonus went to ANY artist's Topic channel, so another artist's same-named song won
  ("I FEEL STRANGE", "BAD4ME" by pluko; "MOLLY TALK"; "Familiar" got Agnes Obel's). Now +6 only for the
  song's own artist, -4 for another artist's Topic, -3 when no song artist is in the channel or title.
  A replay of the owner's real 50-song queue (real YouTube results, old vs new rules) changed exactly
  those 4 picks and nothing else. (2) Spotify names carry "(feat. X)" and uploads don't, so the
  plausibility filter dropped every real upload of "Gang Gang Gangland (feat. YG & Mozzy)" and a mashup
  played; matching now uses `coreName` (feat/ft/featuring stripped, "(with X)" only when X is a song
  artist), and "mashup" is a wrong-version word. Lists from some plugin endpoints carry **no length**
  (`durationMs` 0, all 50 songs of one queue), which switches the length check off, so the artist checks
  matter. Picking a version in "Alternative track sources" is saved (`swapWithSibling` writes
  `source_match_table`). Tests: `rank_results_test.dart` groups "artist check" / "featured artists"
  (checked to fail on the old rules). YouTube returns **0 results** for some full names ("Jon Casey Angrybaby
  CLENCH MY FIST (Jon Casey VIP)", any query with "VIP" or the brackets) while the plain name lists the exact
  upload, so `searchYouTubeFor` retries an empty search without brackets (log `YouTube found nothing for
  ...; trying ...`); tests in `youtube_query_test.dart`.

## Search tabs vs plugin 0.2.2

- **Search tabs vs the Spotify plugin 0.2.2** (`lib/services/metadata/endpoints/search.dart`): its client
  passes Spotify's `nextOffset` as `offset` (null on the last page) and `Converters.paginated` adds to it,
  so every Artists/Songs/Albums/Playlists tab with 20 results or fewer failed (`converter.ht ... '+' was
  called on null`), and with more results "load more" skipped a page (next offset = Spotify's + 20) and
  21-39 results never offered page 2. The app now works the paging out itself (`fixSearchPaging`) and on
  the crash uses the All search's results for page 1 (`searchPageWithFallback`, log `Search <tab> "<q>":
  the plugin failed on its last page`). Source read at plugin tag 0.2.2 + sonic-liberation/spotify-gql-client
  @32f3a26 (`lib/assets/hetu/search.ht`). Tests: `test/services/metadata/search_paging_test.dart`.

## Endless playback

- **Endless playback** (setting on by default; owner wants it: "keep playing similar songs", 2026-10-20) never
  worked on the phone: the plugin's `track.radio` finds Spotify's "<song> Radio" playlist and then crashes on
  any empty entry (track.ht:33, 34 crashes, 0 successes), so the queue just ended. `use_endless_playback.dart`
  now calls `pluginSongsLike` (`lib/services/metadata/radio.dart`): same playlist via the app's search and
  playlist endpoints, else the first artist's top songs; asked once per last song (`radioAskedFor`; it used
  to re-ask on every queue/index change). Tops up in the background once 5 or fewer songs are left
  (`kTopUpWhenLeft` / `needsMoreSongs` in `radio.dart`), not only on the last song. Log `Endless playback: N songs from "<name> Radio"`.
  Tests: `test/services/metadata/radio_test.dart`.

## Lookahead

- Lookahead: `_prepareNearbyTracks` in `audio_player_streams.dart` looks up the audio source for queue
  offsets +1, +2, +3, -1 (`_lookaheadOffsets`) and, for +1 and +2, downloads the whole file into the
  music cache one at a time (`prefetchToCache` in `routes/playback.dart`, only when "cache music" is
  on, temp file `*.prefetch`). It runs as soon as the playing track's own source is resolved (duration
  stream), on every queue change (`ref.listen` on tracks, works while paused) and on every position
  tick; prepared ids are remembered so repeats are free. Tested 2026-10-20: a Connect `reorder` while
  paused triggered the lookup 1 s later. A skip to a prefetched track logs `GET request for track` with no
  `Response for track` line after it, which means it was served from disk. Cache dir:
  `~/Library/Caches/oss.krtirtho.spotube/cached_tracks/`.

## Resume where you left off

- Resume where you left off: `position_ms` in `audio_player_state_table` (schema v11) is saved every 5 s
  while playing and exactly on pause, reset to 0 on track change. On launch `_syncSavedState` stores it
  in `_pendingRestorePosition` and seeks once `durationStream` reports the track loaded (log line
  `Resumed last session at Ns of Ms`). Position writes are skipped until that seek has happened.
  The seek can take 15 s+ (source lookup), so `useProgress` shows `pendingRestorePositionProvider`
  in the player bar straight away; otherwise a relaunch looks like it forgot the spot.
  The saved spot belongs to its song (`_pendingRestoreTrackId`): if the listener picks another song
  before it loads, the spot is dropped instead of starting that song partway in (fixed 0deec5b4).

## Stress-test findings (2026-10-20)

- Stress-test findings fixed 2026-10-20: (1) the restored queue could open before the stream server
  listened, mpv then failed all 51 entries ("Connection refused" x80) and ignored play/next/previous
  until a new queue was loaded; `_syncSavedState` now awaits `serverProvider` first. (2) mpv opens a
  track twice; two appenders on one `.part` left cache files with the slower stream's tail glued on
  (ffmpeg scan: 18 of 287 corrupt, moved to `cached_tracks_bad_2026-10-20/`); `streamTrack` now writes
  only when no `.part` exists, no prefetch is running and the range starts at 0, and sweeps stale
  `.part`/`.prefetch` once per launch. Check a cached file with `ffmpeg -v error -i <f> -f null -`.

## Logs

- **The app's own log is `~/Library/Logs/.spotube_logs`** (hidden file, multi-MB, from
  `lib/services/logger/logger.dart`). **Release builds only.** Debug builds log to the console,
  so run `fvm flutter run -d macos > some.log 2>&1` and read that file (strip ANSI with
  `sed 's/\x1b\[[0-9;]*m//g'`). Format fallbacks log as `Format fallback for "<song>": wanted flac, got mp4 aac 165k`. Tally it by HTTP status and calling function before
  theorising about "error / retry" boxes: on 17-19 Oct it showed 578x 401 (expired Spotify login,
  one burst), 173x 429 (rate limit, mostly Liked Songs), ~110 dropped connections.
- **Phone log:** release builds normally drop info lines (logger's default filter). On iOS release,
  `logger.dart` writes them to `Documents/.spotube_logs` (reset past 5 MB). Pull it with
  `xcrun devicectl device copy from --device <udid> --domain-type appDataContainer --domain-identifier
  nz.kahustudio.spotube --source "Documents/.spotube_logs" --destination <file>`. The same command with
  `copy to` edits the phone's `Library/Application Support/db.sqlite` (close the app first).
  Each error appears twice (`reportError` logs it, then writes its own block), so halve error counts.
  Watch it live: `python3 -u scripts/watch_phone.py` (prints new useful lines every 5 s).

## Debug build shares saved data

- **The debug build shares saved data with the installed Spotube.** Same bundle id
  (`oss.krtirtho.spotube`), so `~/Library/Application Support/oss.krtirtho.spotube/` (plugins,
  login, `db.sqlite` with the saved queue) is shared. A debug run restores whatever queue the
  installed app last had (seen 2026-10-19: a 3,650-track Liked Songs queue), so check
  `sqlite3 db.sqlite "select current_index, length(tracks), collections from audio_player_state_table"`
  before judging queue behaviour. `Debug.xcconfig` only renames the app to "Spotube Dev"; it does
  not split the data.

## Song lookups

- One song used to be looked up 4 times at launch (8 YouTube searches). Two causes, both fixed 2026-10-20:
  `YouTubeExplodeEngine.searchSongs` repeated `searchVideos` (now returns `[]`), and every rebuild of
  `sourcedTrackProvider` starts a whole new lookup without stopping the old one. It now watches the plugin's
  `.future` (no rebuild when it merely finishes loading) and only a real quality change
  (`presetsChangeNeedsNewLookup`). Log line `Lookup #N for "<song>"`; anything above #1 at launch is a regression.
  Test: `test/provider/server/sourced_track_rebuild_test.dart`.
- **A failed lookup used to stay failed**: the lookahead's lookup for a song failed once (search hiccup),
  `sourcedTrackProvider` kept the error, and the song was skipped the instant it was due ("Deviancy",
  "CLENCH MY FIST", 16:26). `_getSourcedTrack` now uses `retryFailedRead` (invalidate + one new lookup,
  log `Looking up "<song>" again`), and no longer goes through `activeTrackSourcesProvider`, which failed
  for every song while the playing song's lookup was failed.

## Cache, downloads and data saver

- Data saver (`lib/services/network_cost.dart`): on mobile data `SourcedTrack.activeStream` picks a
  compressed stream (Opus, then AAC, lowest from 112 kbps) and `prefetchToCache` does nothing; Wi-Fi
  is unchanged. Lossless Sources tops FLAC-only matches up with YouTube streams, which is where the
  compressed stream comes from. The pick is pinned per play (reset by a `/stream` request from byte 0)
  so a network change mid-song cannot swap files; a cached full-quality file still wins on mobile.
- Download gating (2026-10-20): downloads wait until the playing track is 30 s in with 20 s buffered
  ahead (`_safeToDownload`; unknown duration = not safe), drop entries no longer the next 2, and a live
  `/stream` request cancels a prefetch of the same track (`CancelToken` in `_prefetching`). Reason:
  downloads at song start caused warbly audio in the first 15 s when skipping. mpv warn/error lines
  are now captured as `[mpv <prefix> <level>] ...` (`custom_player.dart`); check them first for glitches.
- Cached files are served by `_serveCachedFile` in `routes/playback.dart` with real byte-range support
  (206 + content-range, HEAD = headers only). Before 2026-10-20 the cache branch returned the whole
  file from byte 0 for every request, so each engine seek on a cached track failed (`[mpv ffmpeg
  error] Seek failed`, `flac: invalid sync code`, 10 GETs/s) and was heard as a burst of radio static
  in the first seconds; the lookahead's prefetching made far more tracks play from cache, which is
  why it "started today". Log line `Serving "<song>" from cache (bytes=...)` shows the served range.

## Now playing follows the engine

- `markTrackAsActive` in `provider/audio_player/audio_player.dart` is called from the stream server
  on `/stream/<id>` GETs, so the active index follows what the engine fetches, not only mpv's
  playlist event. Now Playing / Discord follow `activeTrack` via `ref.listen`. Only the latest
  byte-0 request counts (`_latestStartRequest`, noted when the request arrives): a request still
  waiting on its lookup when the listener skipped used to mark the old song active, so the screen
  showed it while the new one played (found by a live skip test, fixed in 0deec5b4).

## Everforest look

- **Look: Everforest, copied from Feishin** (owner picked it from a mood board, 2026-10-19). Theme lives in
  `lib/themes/everforest.dart` (colours as a shadcn `ColorScheme`, Inter typography with Feishin's sizes,
  radius 0.35) and is wired in `main.dart`; glass surfaces are off (`surfaceOpacity: 1, surfaceBlur: 0`).
  The Settings accent-colour picker is intentionally ignored. Inter TTFs are in `assets/fonts/Inter/` (OFL).
  Sidebar is a darker 240px strip, the player bar is flat and **docked** on desktop layouts
  (`isPlayerDocked` in `bottom_player.dart`; `floatingFooter` and the page bottom padding in
  `root_app.dart` follow it), album/artist titles use h1. Phone/compact layouts keep the floating overlay.

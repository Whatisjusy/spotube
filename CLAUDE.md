# Spotube (local dev fork)

Open-source Spotify client built with Flutter. Upstream: https://github.com/KRTirtho/spotube
Owner is non-technical. Explain simply. Target platforms: macOS and iPhone.

## Toolchain (set up 2026-10-19)
- Flutter is managed by **fvm**. Always prefix commands with `fvm`: `fvm flutter ...`, `fvm dart ...`
- Pinned version: `.fvmrc` → 3.35.2 (matches upstream CI). Do not upgrade without reason.
- `.env` exists at repo root (gitignored). Keys are read at build time by `envied`
  into `lib/models/env.dart` → if you change `.env`, re-run build_runner.
- CocoaPods installed via Homebrew.
- **Rust is required** (plugins `metadata_god` and `flutter_discord_rpc` build via Cargokit).
  Installed via `brew install rustup` + `rustup default stable`. PATH line is in `~/.zshrc`;
  if a build says `rustup not found in PATH`, `export PATH="/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:$PATH"` first.

## Everyday commands
```bash
fvm flutter pub get
fvm dart run build_runner build --delete-conflicting-outputs   # regenerate *.g.dart, routes, drift
fvm flutter run -d macos          # run on Mac
fvm flutter run -d <iphone-id>    # run on iPhone (fvm flutter devices to list)
fvm flutter analyze               # 0 errors expected; ~290 upstream warnings/infos are normal
make migrate                      # drift DB migrations after schema changes
```

## Git
- `origin` = the owner's fork https://github.com/Whatisjusy/spotube. `upstream` = KRTirtho/spotube.
- Our working branch is `main` = `upstream/master` (Flutter app, v5.x, the one the owner uses) + this file.
- **Do not base work on `upstream/dev`.** That branch is Spotube 6.0, a from-scratch Kotlin
  Multiplatform / Compose rewrite (Gradle, no pubspec). Different toolchain entirely.
- Keep `main` current with `git fetch upstream && git rebase upstream/master`.
- `skill-observations/` is excluded via `.git/info/exclude`.

## Gotchas
- **Xcode 27 refuses minimum macOS < 12.0 and iOS < 15.0.** Upstream pins 10.15 / 13.0 and several pods lower.
  Local fix (committed on `main`): `macos/Podfile` and `ios/Podfile` platform raised + post_install forces
  `MACOSX_DEPLOYMENT_TARGET=12.0` / `IPHONEOS_DEPLOYMENT_TARGET=15.0` on every pod; both `Runner.xcodeproj` raised.
  Keep this when rebasing. If a build fails with "range of supported deployment target versions", this is why.
- Generated files are not committed upstream; after any pull run build_runner.
- Last.fm keys in `.env` are empty, so scrobbling is off in local builds.
- **The debug build shares saved data with the installed Spotube.** Same bundle id
  (`oss.krtirtho.spotube`), so `~/Library/Application Support/oss.krtirtho.spotube/` (plugins,
  login, `db.sqlite` with the saved queue) is shared. A debug run restores whatever queue the
  installed app last had (seen 2026-10-19: a 3,650-track Liked Songs queue), so check
  `sqlite3 db.sqlite "select current_index, length(tracks), collections from audio_player_state_table"`
  before judging queue behaviour. `Debug.xcconfig` only renames the app to "Spotube Dev"; it does
  not split the data.
- **The app's own log is `~/Library/Logs/.spotube_logs`** (hidden file, multi-MB, from
  `lib/services/logger/logger.dart`). **Release builds only.** Debug builds log to the console,
  so run `fvm flutter run -d macos > some.log 2>&1` and read that file (strip ANSI with
  `sed 's/\x1b\[[0-9;]*m//g'`). Format fallbacks log as `Format fallback for "<song>": wanted flac, got mp4 aac 165k`. Tally it by HTTP status and calling function before
  theorising about "error / retry" boxes: on 17-19 Oct it showed 578x 401 (expired Spotify login,
  one burst), 173x 429 (rate limit, mostly Liked Songs), ~110 dropped connections.
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
- **`fvm flutter analyze` rewrites `pubspec.lock`** (downgrades one package under the pinned SDK).
  `git checkout pubspec.lock` before committing unless deps were meant to change.
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
- **`fvm flutter test`: 2 upstream failures are normal.** `test/drift/app_db/migration_test.dart` no
  longer compiles against the schema, and `test/widget_test.dart` is Flutter's counter template.
- **Debug request logging never runs.** `pipeline.dart` calls `pipeline.addMiddleware(logRequests())`
  and discards the result (shelf pipelines are immutable), so there are no `GET [200] /stream/...` lines.

## iPhone build (working since 2026-10-20)
- Signed with the owner's free Personal Team `232LS727R2` (Apple ID in Xcode). Bundle id
  `nz.kahustudio.spotube` (+ `.HomePlayerWidget`), app group `group.nz.kahustudio.spotube`
  (entitlements, `HomePlayerWidget.swift`, `main.dart`). Upstream's `oss.krtirtho.*` ids belong to
  their team and cannot be signed here. The phone app has its own data: plugins/login set up separately.
- Free team = the app stops opening 7 days after install. Reinstall:
  `fvm flutter build ios --release` then
  `xcrun devicectl device install app --device 00008110-00065DA234A2801E build/ios/iphoneos/Runner.app`.
  Use release: an iOS debug build will not open from the home screen without a debugger attached.
- **iOS 27 kills apps that don't use the UIScene lifecycle** (crash in
  `_UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption`). Fixed with
  `UIApplicationSceneManifest` -> `FlutterSceneDelegate` in `ios/Runner/Info.plist`, and plugins
  registered via `pluginRegistrant` in `AppDelegate.swift` (the window no longer exists at launch).
- home_widget 0.7.0 turns a Dart `null` into NSNull, which crashes UserDefaults on iOS;
  `_saveWidgetData` in `glance.dart` skips nulls on iOS.
- Opening `Runner.xcworkspace` in Xcode 27 rewrites `project.pbxproj` (objectVersion 70) and reorders
  `Info.plist`. Revert that noise before committing. Team id can be read without the UI:
  `defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier`.
- Crash reports: `xcrun devicectl device info files --device <udid> --domain-type systemCrashLogs`,
  then `device copy from ... --source Runner-<date>.ips`.
- **Phone log:** release builds normally drop info lines (logger's default filter). On iOS release,
  `logger.dart` writes them to `Documents/.spotube_logs` (reset past 5 MB). Pull it with
  `xcrun devicectl device copy from --device <udid> --domain-type appDataContainer --domain-identifier
  nz.kahustudio.spotube --source "Documents/.spotube_logs" --destination <file>`. The same command with
  `copy to` edits the phone's `Library/Application Support/db.sqlite` (close the app first).
- iOS 27 refuses connections to `0.0.0.0`, so `SpotubeMedia._host` is `127.0.0.1` on iOS (every track
  failed with "Connection refused" and the engine skipped the whole queue).
- iOS shuts the playback server's listening socket while the app is suspended. `server.dart` probes it on
  resume and on any "Connection refused" from the engine and rebinds (`Playback server stopped answering`).
- Data saver (`lib/services/network_cost.dart`): on mobile data `SourcedTrack.activeStream` picks a
  compressed stream (Opus, then AAC, lowest from 112 kbps) and `prefetchToCache` does nothing; Wi-Fi
  is unchanged. Lossless Sources tops FLAC-only matches up with YouTube streams, which is where the
  compressed stream comes from. The pick is pinned per play (reset by a `/stream` request from byte 0)
  so a network change mid-song cannot swap files; a cached full-quality file still wins on mobile.
- The saved download folder is reset on iOS when it points at an earlier install's container.
- yt-dlp and NewPipe do not exist on iOS; YouTubeExplode is the only engine (no Songs-tab search).
- **YouTube on the phone (tested 2026-10-20, live tests in `test/services/youtube_engine/`):** URLs from
  YouTubeExplode's android/ios clients are served only up to ~1 MB (403 past that, any range size),
  so every YouTube song failed with 403 at the server's HEAD/GET. All other built-in clients are refused
  ("Sign in to confirm you're not a bot"). `visionOsClient` (copied from yt-dlp's `visionos`) with
  `requireWatchPage: true` serves whole files; without the watch page it is refused too. yt-dlp on the
  Mac uses the same client (`c=VISIONOS` in its URLs). If YouTube breaks again, compare with
  `yt-dlp -v --print-traffic --extractor-args youtube:player_client=<client>`.
- `IsolatedYoutubeExplode` used to die silently on any error in its isolate, after which every later
  YouTube call hung forever; errors are now sent back (`_IsolateReply`).
- One song used to be looked up 4 times at launch (8 YouTube searches). Two causes, both fixed 2026-10-20:
  `YouTubeExplodeEngine.searchSongs` repeated `searchVideos` (now returns `[]`), and every rebuild of
  `sourcedTrackProvider` starts a whole new lookup without stopping the old one. It now watches the plugin's
  `.future` (no rebuild when it merely finishes loading) and only a real quality change
  (`presetsChangeNeedsNewLookup`). Log line `Lookup #N for "<song>"`; anything above #1 at launch is a regression.
  Test: `test/provider/server/sourced_track_rebuild_test.dart`.
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
- **A failed lookup used to stay failed**: the lookahead's lookup for a song failed once (search hiccup),
  `sourcedTrackProvider` kept the error, and the song was skipped the instant it was due ("Deviancy",
  "CLENCH MY FIST", 16:26). `_getSourcedTrack` now uses `retryFailedRead` (invalidate + one new lookup,
  log `Looking up "<song>" again`), and no longer goes through `activeTrackSourcesProvider`, which failed
  for every song while the playing song's lookup was failed.
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
- **Search tabs vs the Spotify plugin 0.2.2** (`lib/services/metadata/endpoints/search.dart`): its client
  passes Spotify's `nextOffset` as `offset` (null on the last page) and `Converters.paginated` adds to it,
  so every Artists/Songs/Albums/Playlists tab with 20 results or fewer failed (`converter.ht ... '+' was
  called on null`), and with more results "load more" skipped a page (next offset = Spotify's + 20) and
  21-39 results never offered page 2. The app now works the paging out itself (`fixSearchPaging`) and on
  the crash uses the All search's results for page 1 (`searchPageWithFallback`, log `Search <tab> "<q>":
  the plugin failed on its last page`). Source read at plugin tag 0.2.2 + sonic-liberation/spotify-gql-client
  @32f3a26 (`lib/assets/hetu/search.ht`). Tests: `test/services/metadata/search_paging_test.dart`.
- **Endless playback** (setting on by default; owner wants it: "keep playing similar songs", 2026-10-20) never
  worked on the phone: the plugin's `track.radio` finds Spotify's "<song> Radio" playlist and then crashes on
  any empty entry (track.ht:33, 34 crashes, 0 successes), so the queue just ended. `use_endless_playback.dart`
  now calls `pluginSongsLike` (`lib/services/metadata/radio.dart`): same playlist via the app's search and
  playlist endpoints, else the first artist's top songs; asked once per last song (`radioAskedFor`; it used
  to re-ask on every queue/index change). Log `Endless playback: N songs from "<name> Radio"`.
  Tests: `test/services/metadata/radio_test.dart`.
- **Plugin 0.2.2's `api.spotify.com/v1` calls are refused (2026-10-21).** Only these use it: `artist.related`,
  the details step of `user.savedAlbums`/`savedArtists` (`/v1/albums?ids=`, `/v1/artists?ids=`), `isPlaylistSaved`,
  and playlist create/update/addTracks/removeTracks/follow/unfollow. Every read got 429 on the phone (Retry-After up
  to 59 s, so ~95 s of retries, then an error); query-server (`api-partner.spotify.com/pathfinder`) calls never were.
  `SpotifyGql` (`services/metadata/spotify_gql.dart`) posts persisted queries through the plugin's own logged-in
  client (`metadataPlugin.api.gqlClient`, fetched per attempt: a login replaces it), through the same gate and
  retries. Fans also like uses `queryArtistRelated` (40 artists, <2 s); Library Albums/Artists read the plugin's own
  `libraryV3` reply directly (it already holds names, pictures, album artists); the playlist saved check looks the
  playlist up in the Library playlists list, paging the rest itself. Each falls back to the plugin call on any
  error. Do not page via the shared provider's `fetchAll()` inside a provider that watches it: it invalidates itself
  and the answer waits for the next frame (6 minutes in a hidden window). `areEntitiesInLibrary` (plugin hash)
  returns no saved flag for playlists. Proven on the Mac and the phone. Tests: `related_artists_gql_test.dart`,
  `library_gql_test.dart`.
- **Launch queue (2026-10-21).** `metadataPluginAuthenticatedProvider` rebuilt 3 times per launch (it watched the
  whole plugin list and re-set state on every token refresh), and each rebuild reloaded home sections, new releases,
  section items, profile and library lists. It now watches only "can this plugin log in" and sets state only on a
  real change; sections/releases/section items await its `.future` (counted live: 1 build each). `checkUpdate`
  (GitHub, 2-36 s) skips the 3-slot gate. Plugin calls over 2 s log `Plugin call '<name>' took N ms`.
- "Alternative track sources": the phone page (`pages/player/sources.dart`) had no back button; and the
  sheet re-searched for versions on every rebuild when a song had none (5 searches in 2.6 s); now once per
  song (`siblingsFetchedFor`).
- Cached FLACs were being damaged by `_tagCacheFile` (metadata pointing a few KB off the first frame;
  8-12 of ~45 on the Mac). FLACs are no longer tagged, and `flacLooksPlayable` (`lib/utils/flac_check.dart`)
  deletes a damaged one before serving (log `Deleted damaged cached file`). An empty cached file is
  deleted the same way (`Deleted empty cached file`); it used to fail every request for that song.

## Local behaviour changes (decisions, 2026-10-19)
- Tapping a track in any list = "play from here": queue is that track + the next 50 loaded ones
  (`kQueueWindow` in `use_track_tile_play_callback.dart`). It always rebuilds the queue; it never
  jumps inside an existing queue. The header Play/Shuffle buttons still load the whole collection.
- Lookahead: `_prepareNearbyTracks` in `audio_player_streams.dart` looks up the audio source for queue
  offsets +1, +2, +3, -1 (`_lookaheadOffsets`) and, for +1 and +2, downloads the whole file into the
  music cache one at a time (`prefetchToCache` in `routes/playback.dart`, only when "cache music" is
  on, temp file `*.prefetch`). It runs as soon as the playing track's own source is resolved (duration
  stream), on every queue change (`ref.listen` on tracks, works while paused) and on every position
  tick; prepared ids are remembered so repeats are free. Tested 2026-10-20: a Connect `reorder` while
  paused triggered the lookup 1 s later. A skip to a prefetched track logs `GET request for track` with no
  `Response for track` line after it, which means it was served from disk. Cache dir:
  `~/Library/Caches/oss.krtirtho.spotube/cached_tracks/`.
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
- Stress-test findings fixed 2026-10-20: (1) the restored queue could open before the stream server
  listened, mpv then failed all 51 entries ("Connection refused" x80) and ignored play/next/previous
  until a new queue was loaded; `_syncSavedState` now awaits `serverProvider` first. (2) mpv opens a
  track twice; two appenders on one `.part` left cache files with the slower stream's tail glued on
  (ffmpeg scan: 18 of 287 corrupt, moved to `cached_tracks_bad_2026-10-20/`); `streamTrack` now writes
  only when no `.part` exists, no prefetch is running and the range starts at 0, and sweeps stale
  `.part`/`.prefetch` once per launch. Check a cached file with `ffmpeg -v error -i <f> -f null -`.
- Known slow path: skipping past the prepared window is a cold lookup per track. While the plugin's
  server (`api.monochrome.tf`) is unreachable, `SourcedTrack.audioSourceBreaker`
  (`audio_source_breaker.dart`) skips the plugin for 60 s after 3 timeouts in a row, then probes once;
  log lines `timed out N times in a row; skipping it for 60 s` / `skipped for "<song>" (breaker open)`.
- `markTrackAsActive` in `provider/audio_player/audio_player.dart` is called from the stream server
  on `/stream/<id>` GETs, so the active index follows what the engine fetches, not only mpv's
  playlist event. Now Playing / Discord follow `activeTrack` via `ref.listen`. Only the latest
  byte-0 request counts (`_latestStartRequest`, noted when the request arrives): a request still
  waiting on its lookup when the listener skipped used to mark the old song active, so the screen
  showed it while the new one played (found by a live skip test, fixed in 0deec5b4).
- Debug builds are named **"Spotube Dev"** (set in `macos/Runner/Configs/AppInfo.xcconfig` with
  `PRODUCT_NAME[config=Debug]`). Project-level `Debug.xcconfig` is overridden by that target-level
  file, so put name overrides there. Same bundle id as the installed app, so login/settings are shared.
- A song tapped in **search** plays now and keeps the queue (2026-10-20, owner asked): it goes in straight
  after the current song and the old queue follows (`playNow` / `queueWithPlayNow` in
  `provider/audio_player/audio_player.dart`). Upstream replaced the whole queue after a "clear queue?" prompt.
  Collection lists still use "play from here".
- Liked check (2026-10-20): the plugin's `isSavedTracks` uses Spotify's `isCurated`, which is true for a song
  in ANY of your playlists, so it is no longer used. `likedTrackIdsProvider` (`library/tracks.dart`) loads all
  Liked Songs ids once per launch (50/page, 0.7 s apart; 3,650 took ~90 s, log `Liked Songs loaded: N tracks`)
  and answers the menu, player heart and the new heart button in every track row (`track_tile.dart`).
- Local change: the Getting Started welcome screen never shows on launch (guard removed in `routes.dart`).
- Resume where you left off: `position_ms` in `audio_player_state_table` (schema v11) is saved every 5 s
  while playing and exactly on pause, reset to 0 on track change. On launch `_syncSavedState` stores it
  in `_pendingRestorePosition` and seeks once `durationStream` reports the track loaded (log line
  `Resumed last session at Ns of Ms`). Position writes are skipped until that seek has happened.
  The seek can take 15 s+ (source lookup), so `useProgress` shows `pendingRestorePositionProvider`
  in the player bar straight away; otherwise a relaunch looks like it forgot the spot.
  The saved spot belongs to its song (`_pendingRestoreTrackId`): if the listener picks another song
  before it loads, the spot is dropped instead of starting that song partway in (fixed 0deec5b4).
- **Look: Everforest, copied from Feishin** (owner picked it from a mood board, 2026-10-19). Theme lives in
  `lib/themes/everforest.dart` (colours as a shadcn `ColorScheme`, Inter typography with Feishin's sizes,
  radius 0.35) and is wired in `main.dart`; glass surfaces are off (`surfaceOpacity: 1, surfaceBlur: 0`).
  The Settings accent-colour picker is intentionally ignored. Inter TTFs are in `assets/fonts/Inter/` (OFL).
  Sidebar is a darker 240px strip, the player bar is flat and **docked** on desktop layouts
  (`isPlayerDocked` in `bottom_player.dart`; `floatingFooter` and the page bottom padding in
  `root_app.dart` follow it), album/artist titles use h1. Phone/compact layouts keep the floating overlay.
- **Desktop Now Playing page** (`lib/pages/player/now_playing.dart`, route `now-playing` inside the shell):
  blurred-art backdrop, big art + title left, Lyrics/Queue tabs right. Opened by clicking the artwork in
  the bottom bar (`player_track_details.dart`, desktop widths only). Upstream has no desktop Now Playing.
- Clean-audio plan: `docs/plans/2026-10-19-clean-audio.md`. Phases 1 + 2 done 2026-10-19:
  `getStreamOfQuality` falls back flac -> webm -> mp4 -> anything (never throws on an empty
  list); first run with a plugin defaults to its lossless preset; audio source plugin is now
  Lossless Sources (selected in `plugins_table`, not in SharedPreferences).

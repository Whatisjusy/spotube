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
- **The debug build shares the installed app's data** (same bundle id `oss.krtirtho.spotube`): check the saved queue in `db.sqlite` before judging queue behaviour. Detail: `docs/troubleshooting.md`.
- **Mac log:** release builds write `~/Library/Logs/.spotube_logs`; debug builds log only to the console, so redirect `flutter run` to a file. Tally by HTTP status and caller before theorising. Detail: `docs/troubleshooting.md`.
- **Spotify data comes from a plugin, not this repo** ("Sonic Liberation / Spotify" 0.2.2, source at sonic-liberation/spotube-plugin-spotify tag `0.2.2`). Every call goes through `lib/services/metadata/retry.dart`. Detail: `docs/troubleshooting.md`.
- **`fvm flutter analyze` rewrites `pubspec.lock`** (downgrades one package under the pinned SDK).
  `git checkout pubspec.lock` before committing unless deps were meant to change.
- **Live tests on the Mac:** an older app instance may still be running; back up `audio_player_state_table` and send commands only to your new pid. How-to: `docs/troubleshooting.md`.
- **`fvm flutter test`: 2 upstream failures are normal.** `test/drift/app_db/migration_test.dart` no
  longer compiles against the schema, and `test/widget_test.dart` is Flutter's counter template.
  Code that logs needs `setUpAll(() => AppLogger.initialize(false))`; widgets holding a `TrackTile`
  need MediaKit, so test a pure function instead.
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
  A locked phone makes `devicectl device process launch` fail, but the install worked: ask the owner to open the app.
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
- **Phone log:** iOS release builds write `Documents/.spotube_logs`; pull it with `devicectl ... copy from` or watch live with `python3 -u scripts/watch_phone.py`. Errors appear twice. Detail: `docs/troubleshooting.md`.
- iOS 27 refuses connections to `0.0.0.0`, so `SpotubeMedia._host` is `127.0.0.1` on iOS (every track
  failed with "Connection refused" and the engine skipped the whole queue).
- iOS shuts the playback server's listening socket while the app is suspended. `server.dart` probes it on
  resume and on any "Connection refused" from the engine and rebinds (`Playback server stopped answering`).
- Data saver (`lib/services/network_cost.dart`): on mobile data, play a compressed stream and skip prefetching, pinned per play; Wi-Fi unchanged. Detail: `docs/troubleshooting.md`.
- The saved download folder is reset on iOS when it points at an earlier install's container.
- yt-dlp and NewPipe do not exist on iOS; YouTubeExplode is the only engine (no Songs-tab search).
- **YouTube on the phone only works with `visionOsClient` + `requireWatchPage: true`**; other clients 403 or are refused. Detail: `docs/troubleshooting.md`.
- `IsolatedYoutubeExplode` used to die silently on any error in its isolate, after which every later
  YouTube call hung forever; errors are now sent back (`_IsolateReply`).
- Each song is looked up once at launch: log `Lookup #N for "<song>"`, anything above #1 is a regression (test `sourced_track_rebuild_test.dart`). Detail: `docs/troubleshooting.md`.
- **YouTube's robot check sticks to the engine's session**; `searchVideos` starts a new session and retries once (log `robot check`). Detail: `docs/troubleshooting.md`.
- A failed lookup gets one retry (`retryFailedRead`, log `Looking up "<song>" again`) instead of the song being skipped. Detail: `docs/troubleshooting.md`.
- **YouTube ranking** (`SourcedTrack.scoreMatch` / `rankResults`, `searchYouTubeFor`): rules and the owner's wrong-pick cases in `docs/troubleshooting.md`; tests `rank_results_test.dart`, `youtube_query_test.dart`.
- **Plugin 0.2.2 breaks search paging**; the app pages itself (`fixSearchPaging`, `searchPageWithFallback` in `endpoints/search.dart`). Detail: `docs/troubleshooting.md`.
- **Endless playback** (owner wants it on) uses `pluginSongsLike` in `radio.dart`, topping up at 5 songs left; the plugin's own `track.radio` crashes. Detail: `docs/troubleshooting.md`.
- **Plugin 0.2.2's `api.spotify.com/v1` calls are refused (429, ~95 s of retries); its query-server calls are not.**
  Fans also like, Library Albums/Artists and the playlist saved check now avoid the old API (`SpotifyGql` in
  `services/metadata/spotify_gql.dart`). Playlist edits and follow/unfollow too (`endpoints/playlist.dart`,
  proven live 2026-10-21); only the collaborative switch still uses it. Detail: `docs/troubleshooting.md`.
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
- Lookahead: `_prepareNearbyTracks` (`audio_player_streams.dart`) looks up songs +1..+3 and -1 and downloads +1/+2 into the cache. Detail: `docs/troubleshooting.md`.
- Background downloads wait until the song is 30 s in with 20 s buffered (`_safeToDownload`). For audio glitches, read the `[mpv <prefix> <level>]` lines first. Detail: `docs/troubleshooting.md`.
- Cached songs are served with real byte ranges (`_serveCachedFile`, `routes/playback.dart`); serving the whole file was the radio-static glitch. Log `Serving "<song>" from cache`. Detail: `docs/troubleshooting.md`.
- Stress-test fixes (2026-10-20): the saved queue waits for the stream server, and only one writer fills a cache file. Detail: `docs/troubleshooting.md`.
- Known slow path: skipping past the prepared window is a cold lookup per track. While the plugin's
  server (`api.monochrome.tf`) is unreachable, `SourcedTrack.audioSourceBreaker`
  (`audio_source_breaker.dart`) skips the plugin for 60 s after 3 timeouts in a row, then probes once;
  log lines `timed out N times in a row; skipping it for 60 s` / `skipped for "<song>" (breaker open)`.
- The song shown as playing follows the engine's latest byte-0 `/stream` request (`markTrackAsActive`, `_latestStartRequest`), not only mpv's playlist event. Detail: `docs/troubleshooting.md`.
- Debug builds are named **"Spotube Dev"** (set in `macos/Runner/Configs/AppInfo.xcconfig` with
  `PRODUCT_NAME[config=Debug]`). Project-level `Debug.xcconfig` is overridden by that target-level
  file, so put name overrides there. Same bundle id as the installed app, so login/settings are shared.
- A song tapped in **search** plays now and keeps the queue (2026-10-20, owner asked): it goes in straight
  after the current song and the old queue follows (`playNow` / `queueWithPlayNow` in
  `provider/audio_player/audio_player.dart`). Upstream replaced the whole queue after a "clear queue?" prompt.
  Collection lists still use "play from here".
- The queue list starts at the playing song; played songs are hidden, not removed (owner: "ever flowing but
  still have memory", 2026-10-20). They stay in the player (previous works) and in Recently played
  (`history.addTrack` in `audio_player_streams.dart`); "Show N played" in `player_queue.dart` shows them.
  Reorder indexes are offset by `queueListStart`. With endless playback this makes the queue keep flowing.
- Liked check (2026-10-20): the plugin's `isSavedTracks` uses Spotify's `isCurated`, which is true for a song
  in ANY of your playlists, so it is no longer used. `likedTrackIdsProvider` (`library/tracks.dart`) loads all
  Liked Songs ids once per launch (50/page, 0.7 s apart; 3,650 took ~90 s, log `Liked Songs loaded: N tracks`)
  and answers the menu, player heart and the new heart button in every track row (`track_tile.dart`).
- Local change: the Getting Started welcome screen never shows on launch (guard removed in `routes.dart`).
- Resume where you left off: `position_ms` (schema v11) is saved while playing and restored once the song loads (log `Resumed last session`). Detail: `docs/troubleshooting.md`.
- **Look: Everforest, copied from Feishin** (owner's pick, 2026-10-19): `lib/themes/everforest.dart`, player bar docked on desktop, Settings accent picker ignored on purpose. Detail: `docs/troubleshooting.md`.
- **Desktop Now Playing page** (`lib/pages/player/now_playing.dart`, route `now-playing` inside the shell):
  blurred-art backdrop, big art + title left, Lyrics/Queue tabs right. Opened by clicking the artwork in
  the bottom bar (`player_track_details.dart`, desktop widths only). Upstream has no desktop Now Playing.
- Clean-audio plan: `docs/plans/2026-10-19-clean-audio.md`, all 9 phases done 2026-10-20 (flac -> webm ->
  mp4 fallback, Lossless Sources selected in `plugins_table`, YouTube clean-audio ranking, plugin timeouts).

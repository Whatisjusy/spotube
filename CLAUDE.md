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
- Xcode must be installed from the App Store for macOS/iOS builds (`mas install 497799835` needs an interactive sudo).

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
  endpoint in `lib/services/metadata/endpoints/` goes through it.
- **`fvm flutter analyze` rewrites `pubspec.lock`** (downgrades one package under the pinned SDK).
  `git checkout pubspec.lock` before committing unless deps were meant to change.
- **Testing a running debug build:** `fvm flutter run` launched detached has no stdin, so no hot
  reload; kill the `Debug/Spotube.app` process and relaunch. The app's local control server
  listens on a random port (`lsof -nP -iTCP -sTCP:LISTEN -a -p <pid>`); `GET /playback/toggle-playback`,
  `/playback/next`, `/playback/previous` drive playback for smoke tests, and
  `GET /stream/<trackId>` in the log proves which track the engine actually fetched.

## Local behaviour changes (decisions, 2026-10-19)
- Tapping a track in any list = "play from here": queue is that track + the next 50 loaded ones
  (`kQueueWindow` in `use_track_tile_play_callback.dart`). It always rebuilds the queue; it never
  jumps inside an existing queue. The header Play/Shuffle buttons still load the whole collection.
- Next track's audio source is resolved 5 s into the current track (was 80%).
- `markTrackAsActive` in `audio_player.dart` is called from the stream server on every
  `/stream/<id>` GET, so the active index follows what the engine fetches, not only mpv's
  playlist event. Now Playing / Discord follow `activeTrack` via `ref.listen`.
- Debug builds are named **"Spotube Dev"** (set in `macos/Runner/Configs/AppInfo.xcconfig` with
  `PRODUCT_NAME[config=Debug]`). Project-level `Debug.xcconfig` is overridden by that target-level
  file, so put name overrides there. Same bundle id as the installed app, so login/settings are shared.
- Local change: the Getting Started welcome screen never shows on launch (guard removed in `routes.dart`).
- Resume where you left off: `position_ms` in `audio_player_state_table` (schema v11) is saved every 5 s
  while playing and exactly on pause, reset to 0 on track change. On launch `_syncSavedState` stores it
  in `_pendingRestorePosition` and seeks once `durationStream` reports the track loaded (log line
  `Resumed last session at Ns of Ms`). Position writes are skipped until that seek has happened.
  The seek can take 15 s+ (source lookup), so `useProgress` shows `pendingRestorePositionProvider`
  in the player bar straight away; otherwise a relaunch looks like it forgot the spot.
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

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
- **Xcode 27 refuses minimum macOS < 12.0.** Upstream pins 10.15 and several pods pin 10.14/10.15.
  Local fix (committed on `main`): `macos/Podfile` platform 12.0 + post_install forces
  `MACOSX_DEPLOYMENT_TARGET=12.0` on every pod; `macos/Runner.xcodeproj` raised to 12.0. Keep this when rebasing.
- Generated files are not committed upstream; after any pull run build_runner.
- Last.fm keys in `.env` are empty, so scrobbling is off in local builds.

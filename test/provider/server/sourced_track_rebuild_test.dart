import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/provider/metadata_plugin/audio_source/quality_presets.dart';
import 'package:spotube/provider/server/sourced_track_provider.dart';

// Stand-ins shaped like the real providers at app launch: the plugin loads
// for a moment, and the presets notifier watches it, returns an empty state
// on every build, then fills itself in a moment later.
final _plugin = FutureProvider<String>((ref) async {
  await Future<void>.delayed(const Duration(milliseconds: 30));
  return "lossless-sources";
});

class _Presets extends Notifier<AudioSourcePresetsState> {
  @override
  AudioSourcePresetsState build() {
    ref.watch(_plugin).whenData((_) async {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      state = AudioSourcePresetsState(
          presets: _presets, selectedStreamingContainerIndex: 1);
    });
    return AudioSourcePresetsState();
  }

  void pick(int container) =>
      state = state.copyWith(selectedStreamingContainerIndex: container);
}

final _presetsProvider =
    NotifierProvider<_Presets, AudioSourcePresetsState>(_Presets.new);

final _presets = [
  SpotubeAudioSourceContainerPreset.lossy(
    type: SpotubeMediaCompressionType.lossy,
    name: "mp4",
    qualities: [],
  ),
  SpotubeAudioSourceContainerPreset.lossless(
    type: SpotubeMediaCompressionType.lossless,
    name: "flac",
    qualities: [],
  ),
];

final _network = StreamController<bool>.broadcast();
final _networkProvider = StreamProvider<bool>((ref) => _network.stream);

var oldBuilds = 0;
var newBuilds = 0;

/// What SourcedTrackNotifier did before: watch every input as a value.
final _oldLookup = FutureProvider<int>((ref) async {
  ref.watch(_plugin);
  ref.watch(_presetsProvider);
  ref.watch(_networkProvider);
  return ++oldBuilds;
});

/// What it does now.
final _newLookup = FutureProvider<int>((ref) async {
  ref.watch(_plugin.future);
  ref.watch(_networkProvider);
  ref.listen(_presetsProvider, (previous, next) {
    if (presetsChangeNeedsNewLookup(previous, next)) ref.invalidateSelf();
  });
  return ++newBuilds;
});

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 80));

void main() {
  test("old watches look a song up again while the app is starting", () async {
    oldBuilds = 0;
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.listen(_oldLookup, (_, __) {});
    await settle();
    expect(oldBuilds, greaterThan(1));
  });

  test("new watches: one lookup at launch, again only for real changes",
      () async {
    newBuilds = 0;
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.listen(_newLookup, (_, __) {});
    await settle();
    expect(newBuilds, 1, reason: "plugin loading + presets filling in");

    container.read(_presetsProvider.notifier).pick(0);
    await settle();
    expect(newBuilds, 2, reason: "user picked another quality");

    _network.add(true);
    await settle();
    expect(newBuilds, 3, reason: "Wi-Fi to mobile data");

    container.invalidate(_plugin);
    await settle();
    expect(newBuilds, 4, reason: "plugin replaced");
  });

  test("presetsChangeNeedsNewLookup", () {
    final empty = AudioSourcePresetsState();
    final loaded = AudioSourcePresetsState(
        presets: _presets, selectedStreamingContainerIndex: 1);
    expect(presetsChangeNeedsNewLookup(null, empty), isFalse);
    expect(presetsChangeNeedsNewLookup(empty, loaded), isFalse);
    expect(presetsChangeNeedsNewLookup(loaded, empty), isFalse);
    expect(presetsChangeNeedsNewLookup(loaded, loaded.copyWith()), isFalse);
    expect(
      presetsChangeNeedsNewLookup(
          loaded, loaded.copyWith(selectedStreamingContainerIndex: 0)),
      isTrue,
    );
    expect(
      presetsChangeNeedsNewLookup(
          loaded, loaded.copyWith(selectedStreamingQualityIndex: 2)),
      isTrue,
    );
  });
}

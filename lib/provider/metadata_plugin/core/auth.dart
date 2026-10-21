import 'dart:async';

import 'package:riverpod/riverpod.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/provider/metadata_plugin/metadata_plugin_provider.dart';

class MetadataPluginAuthenticatedNotifier extends AsyncNotifier<bool> {
  @override
  FutureOr<bool> build() async {
    // Local change: watch only whether the plugin can log in. Watching the
    // whole plugin list rebuilt this on every change to it (3 times at each
    // launch on the Mac, 2026-10-21), and every rebuild reloaded each page
    // that watches login state: home sections, new releases, profile,
    // library lists. They queued 2-4 s for the plugin's 3 slots at launch.
    final canLogIn = await ref.watch(
      metadataPluginsProvider.selectAsync(
        (data) =>
            data.defaultMetadataPluginConfig?.abilities
                .contains(PluginAbilities.authentication) ==
            true,
      ),
    );
    if (!canLogIn) {
      return false;
    }

    final defaultPlugin = await ref.watch(metadataPluginProvider.future);
    if (defaultPlugin == null) {
      return false;
    }

    final sub = defaultPlugin.auth.authStateStream.listen((event) {
      // Local change: a token refresh fires this too. Only a real log in or
      // out should reach the pages above.
      final authenticated = defaultPlugin.auth.isAuthenticated();
      if (state.valueOrNull != authenticated) state = AsyncData(authenticated);
    });

    ref.onDispose(() {
      sub.cancel();
    });

    return defaultPlugin.auth.isAuthenticated();
  }
}

final metadataPluginAuthenticatedProvider =
    AsyncNotifierProvider<MetadataPluginAuthenticatedNotifier, bool>(
  MetadataPluginAuthenticatedNotifier.new,
);

class AudioSourcePluginAuthenticatedNotifier extends AsyncNotifier<bool> {
  @override
  FutureOr<bool> build() async {
    final defaultPluginConfig = ref.watch(metadataPluginsProvider);
    if (defaultPluginConfig
            .asData?.value.defaultAudioSourcePluginConfig?.abilities
            .contains(PluginAbilities.authentication) !=
        true) {
      return false;
    }

    final defaultPlugin = await ref.watch(audioSourcePluginProvider.future);
    if (defaultPlugin == null) {
      return false;
    }

    final sub = defaultPlugin.auth.authStateStream.listen((event) {
      state = AsyncData(defaultPlugin.auth.isAuthenticated());
    });

    ref.onDispose(() {
      sub.cancel();
    });

    return defaultPlugin.auth.isAuthenticated();
  }
}

final audioSourcePluginAuthenticatedProvider =
    AsyncNotifierProvider<AudioSourcePluginAuthenticatedNotifier, bool>(
  AudioSourcePluginAuthenticatedNotifier.new,
);

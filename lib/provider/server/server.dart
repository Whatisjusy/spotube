import 'dart:io';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shelf/shelf_io.dart';
import 'package:spotube/provider/server/pipeline.dart';
import 'package:spotube/provider/server/router.dart';
import 'package:spotube/provider/user_preferences/user_preferences_provider.dart';
import 'package:spotube/services/audio_player/audio_player.dart';
import 'package:spotube/services/logger/logger.dart';
import 'package:spotube/utils/platform.dart';

final serverProvider = FutureProvider(
  (ref) async {
    final enabledRemoteConnect = ref.watch(
      userPreferencesProvider.select((value) => value.enableConnect),
    );
    final connectPort = ref.watch(
      userPreferencesProvider.select((value) => value.connectPort),
    );
    final pipeline = ref.watch(pipelineProvider);
    final router = ref.watch(serverRouterProvider);

    // When connect port is -1, we need to generate a random port
    // but we shouldn't reset it if it's already been set (caused by a state change)
    if (connectPort == -1) {
      if (SpotubeMedia.serverPort == 0) {
        final port = Random().nextInt(17500) + 5000;
        SpotubeMedia.serverPort = port;
      }
    } else {
      SpotubeMedia.serverPort = connectPort;
    }

    final handler = pipeline.addHandler(router.call);
    final address = enabledRemoteConnect
        ? InternetAddress.anyIPv4
        : InternetAddress.loopbackIPv4;
    var server = await serve(handler, address, SpotubeMedia.serverPort);

    AppLogger.log.t(
      'Playback server at http://${server.address.host}:${server.port}',
    );

    ref.onDispose(() {
      server.close();
    });

    // iOS shuts an app's listening sockets while it is suspended. Back in the
    // foreground every /stream request is then refused and the engine skips
    // through the whole queue. Probe the server on resume and on a refused
    // connection, and bind it again on the same port if it no longer answers
    // (the queued URLs carry that port). The dead server must be fully closed
    // first: Dart refuses a second bind to a port it still has registered.
    if (kIsIOS) {
      var checking = false;
      Future<void> restartIfDead() async {
        if (checking) return;
        checking = true;
        try {
          final socket = await Socket.connect(
            InternetAddress.loopbackIPv4,
            SpotubeMedia.serverPort,
            timeout: const Duration(seconds: 1),
          );
          socket.destroy();
        } catch (_) {
          AppLogger.log.w(
            "Playback server stopped answering; starting it again",
          );
          await server.close(force: true).catchError((_) {});
          for (var attempt = 1; attempt <= 5; attempt++) {
            try {
              server = await serve(handler, address, SpotubeMedia.serverPort);
              AppLogger.log.i("Playback server back on port ${server.port}");
              break;
            } catch (e, stack) {
              if (attempt == 5) AppLogger.reportError(e, stack);
              await Future.delayed(Duration(milliseconds: 300 * attempt));
            }
          }
        } finally {
          checking = false;
        }
      }

      final lifecycle = AppLifecycleListener(onResume: restartIfDead);
      final errors = audioPlayer.errorStream.listen((error) {
        if (error.contains("Connection refused")) restartIfDead();
      });
      ref.onDispose(() {
        lifecycle.dispose();
        errors.cancel();
      });
    }

    return (
      server: server,
      port: SpotubeMedia.serverPort,
    );
  },
);

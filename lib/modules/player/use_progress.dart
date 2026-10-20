import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:spotube/provider/audio_player/audio_player.dart';
import 'package:spotube/services/audio_player/audio_player.dart';

({
  double progressStatic,
  Duration position,
  Duration duration,
  double bufferProgress
}) useProgress(WidgetRef ref) {
  final bufferProgress =
      useStream(audioPlayer.bufferedPositionStream).data?.inSeconds ?? 0;

  final duration = useState(Duration.zero);
  final position = useState(Duration.zero);

  // After a relaunch the engine reports 0:00 until the track has loaded and
  // been seeked. Show the saved spot (and the track's known length) meanwhile.
  final pendingRestore = ref.watch(pendingRestorePositionProvider);
  final trackDurationMs = ref.watch(
    audioPlayerProvider.select((s) => s.activeTrack?.durationMs ?? 0),
  );
  final shownPosition = pendingRestore ?? position.value;
  final shownDuration =
      duration.value == Duration.zero && pendingRestore != null
          ? Duration(milliseconds: trackDurationMs)
          : duration.value;

  final sliderMax = shownDuration.inSeconds;
  final sliderValue = shownPosition.inSeconds;

  useEffect(() {
    duration.value = audioPlayer.duration;

    final durationSubscription = audioPlayer.durationStream.listen((event) {
      duration.value = event;
    });

    position.value = audioPlayer.position;

    var lastPosition = position.value;

    // audioPlayer.positionStream is fired every 200ms and only 1s delay is
    // enough. Thus only update the position if the difference is more than 1s
    // Reduces CPU usage
    final positionSubscription = audioPlayer.positionStream.listen((event) {
      final diff = event.inMilliseconds - lastPosition.inMilliseconds;
      if (event.inMilliseconds > 1000 && diff < 1000 && diff > 0) return;

      lastPosition = event;
      position.value = event;
    });

    return () {
      positionSubscription.cancel();
      durationSubscription.cancel();
    };
  }, []);

  return (
    progressStatic:
        sliderMax == 0 || sliderValue > sliderMax ? 0 : sliderValue / sliderMax,
    position: shownPosition,
    duration: shownDuration,
    bufferProgress: sliderMax == 0 || bufferProgress > sliderMax
        ? 0
        : bufferProgress / sliderMax,
  );
}

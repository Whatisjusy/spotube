import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:spotube/services/logger/logger.dart';
import 'package:spotube/utils/platform.dart';

/// Tracks whether the phone is on mobile data, so playback can trade FLAC
/// for a compressed stream and skip whole-song downloads ahead. Wi-Fi,
/// Ethernet and every desktop count as unmetered.
class NetworkCost {
  static bool onMobileData = false;

  static final _changes = StreamController<bool>.broadcast();

  /// Emits the new [onMobileData] value whenever it flips.
  static Stream<bool> get changes => _changes.stream;

  static StreamSubscription<List<ConnectivityResult>>? _subscription;

  static Future<void> initialize() async {
    if (!kIsMobile) return;
    try {
      final connectivity = Connectivity();
      update(await connectivity.checkConnectivity());
      _subscription ??= connectivity.onConnectivityChanged.listen(update);
    } catch (e, stack) {
      AppLogger.reportError(e, stack);
    }
  }

  static void update(List<ConnectivityResult> results) {
    final mobile = isMetered(results);
    if (mobile != onMobileData) {
      AppLogger.log.i(
        mobile
            ? "Network: mobile data, data saver on (compressed audio, no downloads ahead)"
            : "Network: Wi-Fi, full quality",
      );
    }
    final changed = mobile != onMobileData;
    onMobileData = mobile;
    if (changed) _changes.add(mobile);
  }

  /// Mobile data with no Wi-Fi or Ethernet alongside it.
  static bool isMetered(List<ConnectivityResult> results) =>
      results.contains(ConnectivityResult.mobile) &&
      !results.contains(ConnectivityResult.wifi) &&
      !results.contains(ConnectivityResult.ethernet);
}

/// Stops calling an audio source plugin that keeps timing out.
///
/// After [threshold] timeouts in a row the plugin is skipped for [cooldown],
/// so every lookup stops paying the full timeout while the plugin's server is
/// unreachable. When the cooldown ends the next lookup tries the plugin once;
/// a success closes the breaker, another timeout re-opens it for a further
/// cooldown. [now] is injectable for tests.
class AudioSourceBreaker {
  AudioSourceBreaker({
    this.threshold = 3,
    this.cooldown = const Duration(seconds: 60),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final int threshold;
  final Duration cooldown;
  final DateTime Function() _now;

  int _consecutiveTimeouts = 0;
  DateTime? _openUntil;

  int get consecutiveTimeouts => _consecutiveTimeouts;

  /// True while the plugin should be skipped.
  bool get isOpen {
    final until = _openUntil;
    return until != null && _now().isBefore(until);
  }

  /// Returns true when this timeout opened (or re-opened) the breaker.
  bool recordTimeout() {
    _consecutiveTimeouts++;
    if (_consecutiveTimeouts < threshold) return false;
    _openUntil = _now().add(cooldown);
    return true;
  }

  void recordSuccess() {
    _consecutiveTimeouts = 0;
    _openUntil = null;
  }
}

import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:shadcn_flutter/shadcn_flutter_extension.dart';
import 'package:spotube/collections/spotube_icons.dart';
import 'package:spotube/extensions/context.dart';

/// A quiet, one-line failure notice with a retry button.
///
/// Used for non-essential sections (home page rows) where a transient
/// network or rate-limit error should not shout at the user with a full
/// error card and stack of logs.
class SoftErrorRow extends StatelessWidget {
  final VoidCallback? onRetry;
  const SoftErrorRow({super.key, this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        spacing: 8,
        children: [
          Icon(
            SpotubeIcons.error,
            size: 16,
            color: context.theme.colorScheme.mutedForeground,
          ),
          Flexible(
            child: Text(context.l10n.an_error_occurred).muted().small(),
          ),
          if (onRetry != null)
            Button.ghost(
              onPressed: onRetry,
              leading: const Icon(SpotubeIcons.refresh, size: 14),
              child: Text(context.l10n.retry),
            ),
        ],
      ),
    );
  }
}

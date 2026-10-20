import 'package:auto_route/auto_route.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:spotube/components/button/back_button.dart';
import 'package:spotube/components/titlebar/titlebar.dart';
import 'package:spotube/modules/player/sibling_tracks_sheet.dart';

@RoutePage()
class PlayerTrackSourcesPage extends StatelessWidget {
  const PlayerTrackSourcesPage({super.key});

  @override
  Widget build(BuildContext context) {
    // Phones open this as a full page, which had no way back (2026-10-20).
    // The list keeps its own "Alternative track sources" heading.
    return const SafeArea(
      bottom: false,
      child: Scaffold(
        headers: [
          TitleBar(leading: [BackButton()]),
        ],
        child: SiblingTracksSheet(floating: false),
      ),
    );
  }
}

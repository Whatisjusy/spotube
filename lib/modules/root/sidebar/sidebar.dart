import 'package:auto_route/auto_route.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'package:spotube/collections/side_bar_tiles.dart';
import 'package:spotube/models/database/database.dart';
import 'package:spotube/extensions/constrains.dart';
import 'package:spotube/extensions/context.dart';
import 'package:spotube/modules/root/bottom_player.dart';
import 'package:spotube/modules/root/sidebar/sidebar_footer.dart';

import 'package:spotube/provider/user_preferences/user_preferences_provider.dart';

class Sidebar extends HookConsumerWidget {
  final Widget child;

  const Sidebar({
    required this.child,
    super.key,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData(:colorScheme) = Theme.of(context);
    final mediaQuery = MediaQuery.sizeOf(context);

    final layoutMode =
        ref.watch(userPreferencesProvider.select((s) => s.layoutMode));

    final sidebarTileList = useMemoized(
      () => getSidebarTileList(context.l10n),
      [context.l10n],
    );

    final sidebarLibraryTileList = useMemoized(
      () => getSidebarLibraryTileList(context.l10n),
      [context.l10n],
    );

    final tileList = [...sidebarTileList, ...sidebarLibraryTileList];

    final router = context.watchRouter;

    final selectedIndex = tileList.indexWhere(
      (e) => router.currentPath.startsWith(e.pathPrefix),
    );

    if (layoutMode == LayoutMode.compact ||
        (mediaQuery.smAndDown && layoutMode == LayoutMode.adaptive)) {
      return child;
    }

    final navigationButtons = [
      // Local (Everforest look): plain wordmark instead of the Cookie script.
      NavigationLabel(
        child: mediaQuery.lgAndUp
            ? DefaultTextStyle(
                style: TextStyle(
                  fontFamily: "Inter",
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.3,
                  color: colorScheme.sidebarForeground,
                ),
                child: const Text("Spotube"),
              )
            : const Text(""),
      ),
      for (final tile in sidebarTileList)
        NavigationButton(
          style: router.currentPath.startsWith(tile.pathPrefix)
              ? const ButtonStyle.secondary()
              : null,
          label: mediaQuery.lgAndUp ? Text(tile.title) : null,
          child: Tooltip(
            tooltip: TooltipContainer(child: Text(tile.title)).call,
            child: Icon(tile.icon),
          ),
          onPressed: () {
            context.navigateTo(tile.route);
          },
        ),
      const NavigationDivider(),
      if (mediaQuery.lgAndUp)
        NavigationLabel(child: Text(context.l10n.library)),
      for (final tile in sidebarLibraryTileList)
        NavigationButton(
          style: router.currentPath.startsWith(tile.pathPrefix)
              ? const ButtonStyle.secondary()
              : null,
          label: mediaQuery.lgAndUp ? Text(tile.title) : null,
          onPressed: () {
            context.navigateTo(tile.route);
          },
          child: Tooltip(
            tooltip: TooltipContainer(child: Text(tile.title)).call,
            child: Icon(tile.icon),
          ),
        ),
    ];

    // Local (Everforest look, copied from Feishin): the sidebar sits on a
    // darker strip with a 1px border on its right, 240px wide.
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          decoration: BoxDecoration(
            color: colorScheme.sidebar,
            border: Border(
              right: BorderSide(color: colorScheme.sidebarBorder, width: 1),
            ),
          ),
          child: Column(
            children: [
              Expanded(
                child: mediaQuery.lgAndUp
                    ? NavigationSidebar(
                        backgroundColor: colorScheme.sidebar,
                        constraints: const BoxConstraints(
                          minWidth: 240,
                          maxWidth: 240,
                        ),
                        index: selectedIndex,
                        onSelected: (index) {
                          final tile = tileList[index];
                          context.navigateTo(tile.route);
                        },
                        children: navigationButtons,
                      )
                    : NavigationRail(
                        backgroundColor: colorScheme.sidebar,
                        alignment: NavigationRailAlignment.start,
                        index: selectedIndex,
                        onSelected: (index) {
                          final tile = tileList[index];
                          context.navigateTo(tile.route);
                        },
                        children: navigationButtons,
                      ),
              ),
              const SidebarFooter(),
              // Room above the floating player bar; none needed when docked.
              if (!isPlayerDocked(context, layoutMode))
                if (mediaQuery.lgAndUp) const Gap(130) else const Gap(65),
            ],
          ),
        ),
        Expanded(child: child),
      ],
    );
  }
}

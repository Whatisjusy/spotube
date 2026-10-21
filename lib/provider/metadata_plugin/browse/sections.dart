import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/provider/metadata_plugin/core/auth.dart';
import 'package:spotube/provider/metadata_plugin/utils/paginated.dart';

class MetadataPluginBrowseSectionsNotifier
    extends PaginatedAsyncNotifier<SpotubeBrowseSectionObject<Object>> {
  @override
  Future<SpotubePaginationResponseObject<SpotubeBrowseSectionObject<Object>>>
      fetch(
    int offset,
    int limit,
  ) async {
    return await (await metadataPlugin).browse.sections(
          limit: limit,
          offset: offset,
        );
  }

  @override
  build() async {
    // Local change: wait for the login state instead of building once
    // before it is known and again after.
    await ref.watch(metadataPluginAuthenticatedProvider.future);
    return await fetch(0, 20);
  }
}

final metadataPluginBrowseSectionsProvider = AsyncNotifierProvider<
    MetadataPluginBrowseSectionsNotifier,
    SpotubePaginationResponseObject<SpotubeBrowseSectionObject<Object>>>(
  () => MetadataPluginBrowseSectionsNotifier(),
);

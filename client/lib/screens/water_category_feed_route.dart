import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config/water_post_taxonomy.dart';
import '../models/water_section.dart';
import '../providers/auth_provider.dart';
import '../providers/post_provider.dart';
import '../providers/water_section_provider.dart';
import 'water_category_feed_screen.dart';

class WaterCategoryFeedRoute extends StatelessWidget {
  final WaterPostCategory? legacyCategory;
  final WaterSection? section;
  final String? sectionSlug;
  final String? initialFilterKey;

  const WaterCategoryFeedRoute({
    super.key,
    this.legacyCategory,
    this.section,
    this.sectionSlug,
    this.initialFilterKey,
  }) : assert(legacyCategory != null || section != null || sectionSlug != null,
            'Must provide at least one of: legacyCategory, section, sectionSlug');

  WaterCategoryFeedRoute.fromLegacyCategory(WaterPostCategory category,
      {String? initialFilterKey})
      : this(
            key: ValueKey('legacy_${category.value}'),
            legacyCategory: category,
            initialFilterKey: initialFilterKey);

  WaterCategoryFeedRoute.fromSection(WaterSection section,
      {String? initialFilterKey})
      : this(
            key: ValueKey('section_${section.slug}'),
            section: section,
            initialFilterKey: initialFilterKey);

  @override
  Widget build(BuildContext context) {
    WaterSection resolved;
    if (section != null) {
      resolved = section!;
    } else if (legacyCategory != null) {
      resolved = WaterSection.fromLegacyCategory(legacyCategory!);
    } else {
      // Only sectionSlug provided â€?lookup from provider
      final provider = context.read<WaterSectionProvider>();
      resolved = provider.getBySlugOrFallback(sectionSlug!);
    }

    return WaterCategoryFeedScreen(
      key: ValueKey('water-feed-${resolved.slug}'),
      category: legacyCategory ??
          waterCategoryOf(resolved.slug) ??
          kWaterPostCategories[0],
      section: resolved,
      initialFilterKey: initialFilterKey,
    );
  }
}

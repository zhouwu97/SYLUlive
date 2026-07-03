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

  const WaterCategoryFeedRoute({
    super.key,
    this.legacyCategory,
    this.section,
    this.sectionSlug,
  }) : assert(legacyCategory != null || section != null || sectionSlug != null,
            'Must provide at least one of: legacyCategory, section, sectionSlug');

  WaterCategoryFeedRoute.fromLegacyCategory(WaterPostCategory category)
      : this(key: ValueKey('legacy_${category.value}'), legacyCategory: category);

  WaterCategoryFeedRoute.fromSection(WaterSection section)
      : this(key: ValueKey('section_${section.slug}'), section: section);

  @override
  Widget build(BuildContext context) {
    WaterSection resolved;
    if (section != null) {
      resolved = section!;
    } else if (legacyCategory != null) {
      resolved = WaterSection.fromLegacyCategory(legacyCategory!);
    } else {
      // Only sectionSlug provided — lookup from provider
      final provider = context.read<WaterSectionProvider>();
      resolved =
          provider.getBySlugOrFallback(sectionSlug!);
    }

    return ChangeNotifierProvider(
      create: (context) => PostProvider(
        context.read<AuthProvider>().dio,
        enableCache: false,
      ),
      child: WaterCategoryFeedScreen(
        category: legacyCategory ?? waterCategoryOf(resolved.slug) ?? kWaterPostCategories[0],
        section: resolved,
      ),
    );
  }
}

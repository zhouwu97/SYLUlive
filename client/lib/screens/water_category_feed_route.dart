import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config/water_post_taxonomy.dart';
import '../providers/auth_provider.dart';
import '../providers/post_provider.dart';
import 'water_category_feed_screen.dart';

class WaterCategoryFeedRoute extends StatelessWidget {
  final WaterPostCategory category;

  const WaterCategoryFeedRoute({super.key, required this.category});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (context) => PostProvider(
        context.read<AuthProvider>().dio,
        enableCache: false,
      ),
      child: WaterCategoryFeedScreen(category: category),
    );
  }
}

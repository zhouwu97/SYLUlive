import re

# 1. Create water_section_directory_screen.dart
directory_screen_path = 'client/lib/screens/water_section_directory_screen.dart'
directory_screen_content = """import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/water_section_provider.dart';
import '../models/water_section.dart';
import '../widgets/water_section/section_avatar.dart';
import 'water_category_feed_screen.dart';

class WaterSectionDirectoryScreen extends StatefulWidget {
  const WaterSectionDirectoryScreen({super.key});

  @override
  State<WaterSectionDirectoryScreen> createState() => _WaterSectionDirectoryScreenState();
}

class _WaterSectionDirectoryScreenState extends State<WaterSectionDirectoryScreen> {
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final backgroundColor = isDark ? const Color(0xFF0D1117) : const Color(0xFFF7F8FA);
    
    final sectionProvider = context.watch<WaterSectionProvider>();
    final sections = sectionProvider.activeSections;

    return Scaffold(
      backgroundColor: backgroundColor,
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            _buildHeader(isDark),
            _buildSummaryBar(isDark, sections),
            if (sections.isEmpty)
              SliverFillRemaining(
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.inbox_outlined, size: 48, color: isDark ? Colors.white38 : Colors.black38),
                      const SizedBox(height: 16),
                      Text('暂无可用版块\\n稍后刷新试试', textAlign: TextAlign.center, style: TextStyle(color: isDark ? Colors.white54 : Colors.black54)),
                    ],
                  ),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                sliver: _buildSectionGrid(isDark, sections),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(bool isDark) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
        child: Row(
          children: [
            GestureDetector(
              onTap: () => Navigator.pop(context),
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: isDark ? Colors.white.withValues(alpha: 0.1) : Colors.black.withValues(alpha: 0.05),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.arrow_back, size: 20, color: isDark ? Colors.white : Colors.black87),
              ),
            ),
            const SizedBox(width: 16),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '水帖分类',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '按学习、生活、竞赛、求助来逛',
                  style: TextStyle(
                    fontSize: 13,
                    color: isDark ? Colors.white54 : Colors.black54,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSummaryBar(bool isDark, List<WaterSection> sections) {
    int followCount = sections.where((s) => s.isFollowed).length;
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            _buildSummaryChip(isDark, '${sections.length} 个版块', Icons.category_outlined),
            const SizedBox(width: 8),
            _buildSummaryChip(isDark, '已关注 $followCount', Icons.favorite_border),
          ],
        ),
      ),
    );
  }

  Widget _buildSummaryChip(bool isDark, String text, IconData icon) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: isDark ? Colors.white.withValues(alpha: 0.05) : Colors.black.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: isDark ? Colors.white70 : Colors.black54),
          const SizedBox(width: 6),
          Text(text, style: TextStyle(fontSize: 13, color: isDark ? Colors.white70 : Colors.black54)),
        ],
      ),
    );
  }

  Widget _buildSectionGrid(bool isDark, List<WaterSection> sections) {
    final width = MediaQuery.of(context).size.width;
    final crossAxisCount = width >= 640 ? 3 : 2;

    return SliverGrid(
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        childAspectRatio: 1.65,
      ),
      delegate: SliverChildBuilderDelegate(
        (context, index) {
          return _buildSectionCard(isDark, sections[index]);
        },
        childCount: sections.length,
      ),
    );
  }

  Widget _buildSectionCard(bool isDark, WaterSection section) {
    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => WaterCategoryFeedRoute.fromSection(section),
          ),
        );
      },
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1F2937) : Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isDark ? Colors.white.withValues(alpha: 0.08) : Colors.grey.withValues(alpha: 0.15),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                SectionAvatar(section: section, size: 36),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    section.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: isDark ? Colors.white : Colors.black87,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: Text(
                section.description.isNotEmpty ? section.description : section.subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: isDark ? Colors.white54 : Colors.black54,
                  height: 1.4,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${section.postCount}帖 · ${section.followerCount}关注',
                  style: TextStyle(
                    fontSize: 11,
                    color: isDark ? Colors.white38 : Colors.black38,
                  ),
                ),
                if (section.isFollowed)
                  Text(
                    '已关注',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: isDark ? const Color(0xFF34D399) : const Color(0xFF059669),
                    ),
                  )
                else if (section.myLevel != null && section.myLevel!.level > 1)
                  Text(
                    section.myLevel!.levelLabel,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: isDark ? Colors.orange[300] : Colors.orange[700],
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
"""

with open(directory_screen_path, 'w', encoding='utf-8') as f:
    f.write(directory_screen_content)


# 2. Modify home_service_drawer.dart
drawer_path = 'client/lib/widgets/home_service_drawer.dart'
with open(drawer_path, 'r', encoding='utf-8') as f:
    drawer_content = f.read()

drawer_content = drawer_content.replace('onOpenAllWaterPosts', 'onOpenWaterSectionDirectory')

with open(drawer_path, 'w', encoding='utf-8') as f:
    f.write(drawer_content)


# 3. Modify shuitie_screen.dart
shuitie_path = 'client/lib/screens/shuitie_screen.dart'
with open(shuitie_path, 'r', encoding='utf-8') as f:
    shuitie_content = f.read()

shuitie_content = shuitie_content.replace('onOpenAllWaterPosts', 'onOpenWaterSectionDirectory')

shuitie_content = re.sub(
    r"onOpenWaterSectionDirectory:\s*\(\)\s*\{\s*_closePanelThenOpen\(dialogContext,\s*\(\)\s*\{\s*_changeFeedMode\('all'\);\s*\}\);\s*\},",
    r"onOpenWaterSectionDirectory: () {\n                  _closePanelThenOpen(dialogContext, () {\n                    Navigator.push(\n                      context,\n                      MaterialPageRoute(\n                        builder: (_) => const WaterSectionDirectoryScreen(),\n                      ),\n                    );\n                  });\n                },",
    shuitie_content
)

if 'water_section_directory_screen.dart' not in shuitie_content:
    shuitie_content = shuitie_content.replace(
        "import '../widgets/water_section/section_filter_header.dart';",
        "import '../widgets/water_section/section_filter_header.dart';\nimport 'water_section_directory_screen.dart';"
    )

with open(shuitie_path, 'w', encoding='utf-8') as f:
    f.write(shuitie_content)

# 4. Remove duplicate import in water_category_feed_screen.dart
feed_path = 'client/lib/screens/water_category_feed_screen.dart'
with open(feed_path, 'r', encoding='utf-8') as f:
    feed_content = f.read()

# Replace the first duplicate if there are multiple
lines = feed_content.split('\n')
seen_imports = set()
new_lines = []
for line in lines:
    if line.startswith("import '../widgets/water_section/section_floating_dock.dart';"):
        if 'dock' not in seen_imports:
            seen_imports.add('dock')
            new_lines.append(line)
    else:
        new_lines.append(line)

with open(feed_path, 'w', encoding='utf-8') as f:
    f.write('\n'.join(new_lines))

print("All tasks completed")

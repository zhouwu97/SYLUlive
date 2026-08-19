import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../theme/app_colors.dart';
import '../providers/water_section_provider.dart';
import '../models/water_section.dart';
import '../widgets/water_section/section_avatar.dart';
import 'water_category_feed_route.dart';
import 'poll/poll_center_screen.dart';

class WaterSectionDirectoryScreen extends StatefulWidget {
  const WaterSectionDirectoryScreen({super.key});

  @override
  State<WaterSectionDirectoryScreen> createState() =>
      _WaterSectionDirectoryScreenState();
}

class _WaterSectionDirectoryScreenState
    extends State<WaterSectionDirectoryScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final backgroundColor =
        isDark ? const Color(0xFF0D1117) : const Color(0xFFFFFAF4);

    final sectionProvider = context.watch<WaterSectionProvider>();
    final allSections = sectionProvider.activeSections;

    // Local filter
    final displaySections = allSections.where((s) {
      if (_searchQuery.isEmpty) return true;
      final query = _searchQuery.toLowerCase();
      return s.title.toLowerCase().contains(query) ||
          s.subtitle.toLowerCase().contains(query) ||
          s.description.toLowerCase().contains(query);
    }).toList();
    final showPollEntry = _searchQuery.isEmpty ||
        const ['投票', '选择', '意见', '调查'].any(_searchQuery.contains);

    return Scaffold(
      backgroundColor: backgroundColor,
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            _buildHeader(isDark),
            _buildSearchBar(isDark),
            if (_searchQuery.isEmpty) _buildMyFollows(isDark, allSections),
            if (showPollEntry) _buildPollEntry(isDark),
            _buildAllSectionsHeader(isDark, displaySections.length),
            if (displaySections.isEmpty && _searchQuery.isNotEmpty && !showPollEntry)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text('没有找到相关版块',
                          style: TextStyle(
                              fontSize: 15,
                              color: isDark ? Colors.white70 : Colors.black87)),
                      const SizedBox(height: 8),
                      Text('换个关键词试试',
                          style: TextStyle(
                              fontSize: 13,
                              color: isDark ? Colors.white38 : Colors.black38)),
                    ],
                  ),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                sliver: _buildSectionList(isDark, displaySections),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 40)),
          ],
        ),
      ),
    );
  }

  Widget _buildPollEntry(bool isDark) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PollCenterScreen())),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: isDark ? AppColors.brandSurfaceDark : AppColors.brandSurfaceLight,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: AppColors.brandPrimary.withValues(alpha: 0.18)),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('特殊版块', style: TextStyle(fontSize: 12, color: isDark ? Colors.white60 : Colors.black54)),
              const SizedBox(height: 8),
              Row(children: [
                CircleAvatar(backgroundColor: isDark ? AppColors.surfaceMutedDark : AppColors.brandSurfaceLight, child: const Icon(Icons.poll_outlined, color: AppColors.brandPrimary)),
                const SizedBox(width: 12),
                const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('校园投票', style: TextStyle(fontWeight: FontWeight.w800)), SizedBox(height: 3), Text('参与校园话题、选择与意见征集', style: TextStyle(fontSize: 12))])),
                const Icon(Icons.chevron_right, color: AppColors.brandPrimary),
              ]),
              const SizedBox(height: 8),
              Wrap(spacing: 4, children: [
                _pollShortcut('推荐', 'recommend'),
                _pollShortcut('最新', 'latest'),
                _pollShortcut('即将结束', 'ending'),
              ]),
              const SizedBox(height: 4),
              Text('特殊版块 · 独立发布模式', style: TextStyle(fontSize: 11, color: isDark ? Colors.white54 : Colors.black45)),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _pollShortcut(String label, String sort) {
    return TextButton(
      onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => PollCenterScreen(initialSort: sort))),
      child: Text(label),
    );
  }

  Widget _buildHeader(bool isDark) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 12),
        child: Row(
          children: [
            GestureDetector(
              onTap: () => Navigator.pop(context),
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.1)
                      : Colors.black.withValues(alpha: 0.05),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.arrow_back,
                    size: 20, color: isDark ? Colors.white : Colors.black87),
              ),
            ),
            const SizedBox(width: 16),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '社区版块',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '按学习、生活、竞赛和求助来逛',
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

  Widget _buildSearchBar(bool isDark) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Container(
          height: 44,
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1F2937) : Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.08)
                  : const Color(0xFFECE4DA),
            ),
          ),
          child: TextField(
            controller: _searchController,
            onChanged: (val) {
              setState(() {
                _searchQuery = val;
              });
            },
            style: TextStyle(
              fontSize: 14,
              color: isDark ? Colors.white : Colors.black87,
            ),
            decoration: InputDecoration(
              hintText: '搜索版块、关键词',
              hintStyle: TextStyle(
                color: isDark ? Colors.white38 : Colors.black38,
              ),
              prefixIcon: Icon(Icons.search,
                  size: 20, color: isDark ? Colors.white38 : Colors.black38),
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
              isDense: true,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMyFollows(bool isDark, List<WaterSection> allSections) {
    final followed = allSections.where((s) => s.isFollowed).toList();

    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '我的关注',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: isDark ? Colors.white : Colors.black87,
              ),
            ),
            const SizedBox(height: 12),
            if (followed.isEmpty)
              Container(
                height: 56,
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.05)
                      : Colors.black.withValues(alpha: 0.03),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '还没有关注版块，关注后会优先展示',
                  style: TextStyle(
                    fontSize: 13,
                    color: isDark ? Colors.white54 : Colors.black54,
                  ),
                ),
              )
            else
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: followed.map((s) {
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ActionChip(
                        onPressed: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  WaterCategoryFeedRoute.fromSection(s,
                                      initialFilterKey: 'mode:recommend'),
                            ),
                          );
                        },
                        backgroundColor: isDark
                            ? Colors.white.withValues(alpha: 0.05)
                            : Colors.white,
                        side: BorderSide(
                          color: isDark
                              ? Colors.white.withValues(alpha: 0.1)
                              : const Color(0xFFECE4DA),
                        ),
                        label: Text(s.title),
                        labelStyle: TextStyle(
                          fontSize: 13,
                          color: isDark ? Colors.white : Colors.black87,
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildAllSectionsHeader(bool isDark, int count) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 12),
        child: Row(
          children: [
            Text(
              '全部版块',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: isDark ? Colors.white : Colors.black87,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '$count',
              style: TextStyle(
                fontSize: 13,
                color: isDark ? Colors.white54 : Colors.black54,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionList(bool isDark, List<WaterSection> sections) {
    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, index) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _buildSectionCard(isDark, sections[index]),
          );
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
            builder: (_) => WaterCategoryFeedRoute.fromSection(section,
                initialFilterKey: 'mode:recommend'),
          ),
        );
      },
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1F2937) : Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: isDark
                ? Colors.white.withValues(alpha: 0.08)
                : const Color(0xFFECE4DA),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                SectionAvatar(section: section, size: 40),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        section.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                          color: isDark ? Colors.white : Colors.black87,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        section.description.isNotEmpty
                            ? section.description
                            : section.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark ? Colors.white54 : Colors.black54,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '进入',
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? Colors.white38 : Colors.black38,
                  ),
                ),
                Icon(
                  Icons.chevron_right,
                  size: 16,
                  color: isDark ? Colors.white38 : Colors.black38,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _buildQuickActionBtn(isDark, '推荐', 'mode:recommend', section),
                const SizedBox(width: 8),
                _buildQuickActionBtn(isDark, '最新', 'mode:latest', section),
                const SizedBox(width: 8),
                _buildQuickActionBtn(isDark, '精华', 'mode:featured', section),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQuickActionBtn(
      bool isDark, String label, String filterKey, WaterSection section) {
    return InkWell(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => WaterCategoryFeedRoute.fromSection(section,
                initialFilterKey: filterKey),
          ),
        );
      },
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: isDark
              ? Colors.white.withValues(alpha: 0.05)
              : Colors.black.withValues(alpha: 0.03),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: isDark ? Colors.white70 : Colors.black54,
          ),
        ),
      ),
    );
  }
}

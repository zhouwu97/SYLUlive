import re

path = 'client/lib/screens/shuitie_screen.dart'
with open(path, 'r', encoding='utf-8') as f:
    content = f.read()

# 1. Add _followingExpanded state
content = re.sub(
    r"bool _isRefreshing = false;\s*bool _isScrolled = false;",
    r"bool _isRefreshing = false;\n  bool _isScrolled = false;\n  bool _followingExpanded = false;",
    content
)

# 2. Add community sections grid and following dashboard methods
new_methods = """
  Widget _buildFollowingDashboard(bool isDark, List<Post> posts, bool isFeedLoading) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('关注动态',
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: isDark ? Colors.white : Colors.black87)),
              GestureDetector(
                onTap: () {
                  setState(() => _followingExpanded = true);
                },
                child: Row(
                  children: [
                    Text('全部',
                        style: TextStyle(
                            fontSize: 14,
                            color: isDark ? Colors.white54 : Colors.black54)),
                    Icon(Icons.chevron_right,
                        size: 16,
                        color: isDark ? Colors.white54 : Colors.black54),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (posts.isEmpty && !isFeedLoading)
            Container(
              height: 100,
              width: double.infinity,
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1F2937) : Colors.white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                    color: isDark
                        ? Colors.white.withOpacity(0.1)
                        : Colors.grey.withOpacity(0.2)),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('还没有关注动态',
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: isDark ? Colors.white70 : Colors.black87)),
                  const SizedBox(height: 4),
                  Text('关注版块后会在这里看到更新',
                      style: TextStyle(
                          fontSize: 13,
                          color: isDark ? Colors.white54 : Colors.black54)),
                ],
              ),
            )
          else if (posts.isNotEmpty)
            ...posts.take(2).map((post) => Padding(
                  padding: const EdgeInsets.only(bottom: 8.0),
                  child: PostCard(
                    post: post,
                    isCompact: true,
                    onTap: () {
                      if (ResponsiveUtil.useDesktopShell(context)) {
                        _openPostInSplit(post);
                      } else {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => PostDetailScreen(
                              postId: post.id,
                              isMarket: false,
                              initialPost: post,
                            ),
                          ),
                        );
                      }
                    },
                  ),
                )),
        ],
      ),
    );
  }

  Widget _buildCommunitySectionsGrid(bool isDark) {
    final sections = context.watch<WaterSectionProvider>().sections;
    final displaySections = sections.isNotEmpty
        ? sections
        : kWaterPostCategories
            .map((c) => WaterSection.fromLegacyCategory(c))
            .toList();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('社区版块',
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: isDark ? Colors.white : Colors.black87)),
              GestureDetector(
                onTap: () {
                  _openHomeServicePanel();
                },
                child: Row(
                  children: [
                    Text('全部',
                        style: TextStyle(
                            fontSize: 14,
                            color: isDark ? Colors.white54 : Colors.black54)),
                    Icon(Icons.chevron_right,
                        size: 16,
                        color: isDark ? Colors.white54 : Colors.black54),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.zero,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisExtent: 74,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
            ),
            itemCount: displaySections.length,
            itemBuilder: (context, index) {
              final section = displaySections[index];
              final Color sectionColor =
                  section.colorHex.isNotEmpty
                      ? Color(int.parse(section.colorHex.replaceFirst('#', '0xFF')))
                      : Colors.blue;
              return GestureDetector(
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          WaterCategoryFeedRoute.fromSection(section),
                    ),
                  );
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF1F2937) : Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                        color: isDark
                            ? Colors.white.withOpacity(0.08)
                            : Colors.grey.withOpacity(0.15)),
                  ),
                  child: Row(
                    children: [
                      SectionAvatar(
                        iconKey: section.iconKey,
                        colorHex: section.colorHex,
                        size: 36,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              section.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 14.5,
                                fontWeight: FontWeight.bold,
                                color: isDark ? Colors.white : Colors.black87,
                              ),
                            ),
                            if (section.subtitle.isNotEmpty)
                              Text(
                                section.subtitle,
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
                    ],
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 30),
        ],
      ),
    );
  }

  Widget _buildExpandedFollowingHeader(bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Row(
        children: [
          IconButton(
            icon: Icon(Icons.arrow_back, color: isDark ? Colors.white : Colors.black87),
            onPressed: () => setState(() => _followingExpanded = false),
          ),
          const SizedBox(width: 4),
          Text('关注动态',
              style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.white : Colors.black87)),
        ],
      ),
    );
  }
"""

content = re.sub(
    r"(// ---- 关注模式未登录占位 ----)",
    new_methods.replace('Opacity', 'Values') + r"\n  \1",
    content
)
content = content.replace("withOpacity", "withValues(alpha: ")
content = content.replace("))", "))") # Just to make sure we close if we need, but actually we replace 'withOpacity(x)' with 'withValues(alpha: x)'
content = re.sub(r'withValues\(alpha: ([0-9.]+)\)', r'withValues(alpha: \1)', content)

# 3. Modify _buildFeedModeList slivers
feed_list_pattern = r"(\s+if \(mode == 'following' &&\s+!context\.read<AuthProvider>\(\)\.isLoggedIn\)\s+SliverFillRemaining\(\s+hasScrollBody: false,\s+child: _buildFollowingPlaceholder\(isDark\),\s+\)\s+else if \(isFeedLoading && posts\.isEmpty\)\s+const SliverFillRemaining\(\s+child: Center\(\s+child: CircularProgressIndicator\(\),\s+\),\s+\)\s+else if \(pinnedPosts\.isEmpty && normalPosts\.isEmpty\)\s+SliverFillRemaining\(\s+child: mode == 'following'\s+\?\s+_buildFollowingEmptyState\(isDark\)\s+:\s+_buildEmptyState\(\s+isDark,\s+title: _searchQuery\.isNotEmpty \? '没有找到匹配帖子' : '暂无帖子',\s+subtitle: _searchQuery\.isNotEmpty\s+\? '目前只按标题搜索，换个标题关键词试试'\s+: '发布第一条帖子吧',\s+onRetry: _refresh,\s+\),\s+\)\s+else \.\.\.\[)"
replacement = r"""
              if (mode == 'following' && !_followingExpanded) ...[
                if (!context.read<AuthProvider>().isLoggedIn)
                  SliverToBoxAdapter(
                    child: _buildFollowingPlaceholder(isDark),
                  )
                else
                  SliverToBoxAdapter(
                    child: _buildFollowingDashboard(isDark, normalPosts, isFeedLoading),
                  ),
                SliverToBoxAdapter(
                  child: _buildCommunitySectionsGrid(isDark),
                ),
              ] else ...[
                if (mode == 'following' && _followingExpanded)
                  SliverToBoxAdapter(
                    child: _buildExpandedFollowingHeader(isDark),
                  ),
                if (mode == 'following' && !context.read<AuthProvider>().isLoggedIn)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: _buildFollowingPlaceholder(isDark),
                  )
                else if (isFeedLoading && posts.isEmpty)
                  const SliverFillRemaining(
                    child: Center(
                      child: CircularProgressIndicator(),
                    ),
                  )
                else if (pinnedPosts.isEmpty && normalPosts.isEmpty)
                  SliverFillRemaining(
                    child: mode == 'following'
                        ? _buildFollowingEmptyState(isDark)
                        : _buildEmptyState(
                            isDark,
                            title: _searchQuery.isNotEmpty ? '没有找到匹配帖子' : '暂无帖子',
                            subtitle: _searchQuery.isNotEmpty
                                ? '目前只按标题搜索，换个标题关键词试试'
                                : '发布第一条帖子吧',
                            onRetry: _refresh,
                          ),
                  )
                else ...[
"""

content = re.sub(feed_list_pattern, replacement, content)

# 4. Modify drawer
drawer_path = 'client/lib/widgets/home_service_drawer.dart'
with open(drawer_path, 'r', encoding='utf-8') as f:
    drawer_content = f.read()

drawer_content = drawer_content.replace("'水帖分类'", "'社区版块'")
drawer_content = re.sub(
    r"itemCount: waterSections\.length,",
    r"itemCount: waterSections.length > 4 ? 4 : waterSections.length,",
    drawer_content
)

with open(drawer_path, 'w', encoding='utf-8') as f:
    f.write(drawer_content)

with open(path, 'w', encoding='utf-8') as f:
    f.write(content)

print("Done")

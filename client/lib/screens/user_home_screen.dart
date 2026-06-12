import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:image_picker/image_picker.dart';
import '../providers/auth_provider.dart';
import '../config/api_constants.dart';
import '../widgets/glass_container.dart';
import '../models/user.dart';
import '../models/post.dart';
import '../providers/social_provider.dart';
import '../widgets/post_card.dart';
import 'social_list_screen.dart';

class UserHomeScreen extends StatefulWidget {
  final int? userId;
  const UserHomeScreen({super.key, this.userId});

  @override
  State<UserHomeScreen> createState() => _UserHomeScreenState();
}

class _UserHomeScreenState extends State<UserHomeScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final ScrollController _scrollController = ScrollController();
  User? _user;
  List<Post> _posts = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadData();
    });
  }

  Future<void> _loadData() async {
    if (!mounted) return;
    setState(() => _isLoading = true);
    final targetId = widget.userId ?? context.read<AuthProvider>().user?.id;
    if (targetId != null) {
      final provider = context.read<SocialProvider>();
      final user = await provider.getUserProfile(targetId);
      final posts = await provider.getUserPosts(targetId);
      if (mounted) {
        setState(() {
          _user = user;
          _posts = posts;
        });
      }
    }
    if (mounted) {
      setState(() => _isLoading = false);
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (_isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (_user == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('错误')),
        body: const Center(child: Text('用户不存在或加载失败')),
      );
    }
    
    final user = _user!;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: RefreshIndicator(
        onRefresh: () async {
          // 模拟下拉刷新数据
          await Future.delayed(const Duration(seconds: 1));
        },
        child: NestedScrollView(
          controller: _scrollController,
          headerSliverBuilder: (BuildContext context, bool innerBoxIsScrolled) {
            return <Widget>[
            SliverAppBar(
              expandedHeight: 200.0,
              floating: false,
              pinned: true,
              backgroundColor: Theme.of(context).scaffoldBackgroundColor,
              flexibleSpace: FlexibleSpaceBar(
                collapseMode: CollapseMode.parallax,
                background: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned.fill(
                      child: GestureDetector(
                        onTap: () {
                          if (widget.userId == null || widget.userId == context.read<AuthProvider>().user?.id) {
                            _showEditSheet(context, user);
                          }
                        },
                        child: user.background.isNotEmpty
                            ? CachedNetworkImage(
                                imageUrl: ApiConstants.fullUrl(user.background),
                                fit: BoxFit.cover,
                              )
                            : Image.asset(
                                'assets/images/morenbeijing.jpeg',
                                fit: BoxFit.cover,
                              ),
                      ),
                    ),
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Colors.transparent, isDark ? Colors.black87 : Colors.black54],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                _buildCircleIconButton(Icons.search, () {}),
                const SizedBox(width: 8),
                _buildCircleIconButton(Icons.more_vert, () {}),
                const SizedBox(width: 8),
              ],
            ),

            // 个人信息区域
            SliverToBoxAdapter(
              child: _buildProfileInfo(context, user, isDark),
            ),

            // 标签栏
            SliverPersistentHeader(
              pinned: true,
              delegate: _SliverAppBarDelegate(
                TabBar(
                  controller: _tabController,
                  indicatorSize: TabBarIndicatorSize.label,
                  labelColor: Theme.of(context).primaryColor,
                  unselectedLabelColor: isDark ? Colors.white54 : Colors.black54,
                  indicatorColor: Theme.of(context).primaryColor,
                  indicatorWeight: 3,
                  tabs: [
                    Tab(text: '帖子 ${_posts.length}'),
                    const Tab(text: '智能体 0'),
                  ],
                ),
                isDark ? Theme.of(context).scaffoldBackgroundColor : Colors.white,
              ),
            ),
          ];
        },
        body: TabBarView(
          controller: _tabController,
          children: [
            _posts.isEmpty
                ? const Center(child: Text('暂无帖子'))
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    itemCount: _posts.length,
                    itemBuilder: (context, index) {
                      return PostCard(post: _posts[index]);
                    },
                  ),
            const Center(child: Text('暂无智能体')),
          ],
        ),
      ),
      ),
    );
  }

  Widget _buildProfileInfo(BuildContext context, User user, bool isDark) {
    final isMe = widget.userId == null || widget.userId == context.read<AuthProvider>().user?.id;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Row(
                  children: [
                    ClipOval(
                      child: user.avatar.isNotEmpty
                          ? CachedNetworkImage(
                              imageUrl: ApiConstants.fullUrl(user.avatar),
                              width: 64, height: 64, fit: BoxFit.cover,
                            )
                          : Container(
                              width: 64, height: 64, color: Colors.grey[300],
                              child: const Icon(Icons.person, size: 30, color: Colors.white),
                            ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  user.nickname,
                                  style: const TextStyle(
                                    fontSize: 22,
                                    fontWeight: FontWeight.bold,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          // 性别、ID、吧龄、归属地
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Icon(
                                user.gender == 'female' ? Icons.female : Icons.male,
                                size: 12,
                                color: user.gender == 'female' ? Colors.pink[300] : Colors.blue[300],
                              ),
                              Text('ID ${user.studentId}',
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: isDark ? Colors.white54 : Colors.black54)),
                              Text(user.eduCollege.isNotEmpty ? user.eduCollege : '未知归属',
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: isDark ? Colors.white54 : Colors.black54)),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (isMe)
                OutlinedButton(
                  onPressed: () {
                    _showEditSheet(context, user);
                  },
                  style: OutlinedButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                    side: BorderSide(
                        color: isDark ? Colors.white30 : Colors.black26),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 0),
                    minimumSize: const Size(0, 32),
                  ),
                  child: Text('编辑资料',
                      style: TextStyle(
                          fontSize: 12,
                          color: isDark ? Colors.white : Colors.black87)),
                )
              else if (user.isFollowing)
                OutlinedButton(
                  onPressed: () async {
                    final success = await context.read<SocialProvider>().unfollow(user.id);
                    if (success && mounted) {
                      setState(() {
                        _user!.isFollowing = false;
                        _user!.followersCount = (_user!.followersCount - 1).clamp(0, 999999);
                      });
                    }
                  },
                  child: const Text('已关注'),
                )
              else
                ElevatedButton(
                  onPressed: () async {
                    final success = await context.read<SocialProvider>().follow(user.id);
                    if (success && mounted) {
                      setState(() {
                        _user!.isFollowing = true;
                        _user!.followersCount++;
                      });
                    }
                  },
                  child: const Text('关注'),
                ),
            ],
          ),

          const SizedBox(height: 16),

          // 等级卡片取代简介，紧凑左对齐
          _buildLevelCard(context, user, isDark),

          const SizedBox(height: 16),

          // 统计数据区 (极其精简版)
          Row(
            children: [
              _buildStatItem(user.totalLikesReceived.toString(), '获赞', isDark, null),
              const SizedBox(width: 32),
              _buildStatItem(user.followingCount.toString(), '关注', isDark, isMe ? () {
                Navigator.push(context, MaterialPageRoute(builder: (_) => SocialListScreen(userId: user.id, initialIndex: 0)));
              } : null),
              const SizedBox(width: 32),
              _buildStatItem(user.followersCount.toString(), '粉丝', isDark, isMe ? () {
                Navigator.push(context, MaterialPageRoute(builder: (_) => SocialListScreen(userId: user.id, initialIndex: 1)));
              } : null),
            ],
          ),

          const SizedBox(height: 20),
        ],
      ),
    );
  }

  Widget _buildStatItem(String countStr, String label, bool isDark, VoidCallback? onTap) {
    int count = int.tryParse(countStr) ?? 0;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          AnimatedCount(
            count: count,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: isDark ? Colors.white54 : Colors.grey,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLevelCard(BuildContext context, User user, bool isDark) {
    final nextExp = user.expToNextLevel;
    final progress = user.levelProgress;
    
    return Row(
      children: [
        Text(
          user.levelLabel,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            fontStyle: FontStyle.italic,
            color: Color(user.levelColorValue),
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(
          width: 100,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress,
              backgroundColor: isDark ? Colors.white12 : const Color(0xFFEEEEEE),
              valueColor: AlwaysStoppedAnimation<Color>(
                Color(user.levelColorValue),
              ),
              minHeight: 6,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Text(
          '${user.exp}/${nextExp}',
          style: TextStyle(
            fontSize: 12,
            color: isDark ? Colors.white54 : Colors.black54,
          ),
        ),
        const SizedBox(width: 16),
        const Icon(Icons.monetization_on, size: 14, color: Colors.amber),
        const SizedBox(width: 4),
        Text(
          '${user.credits}',
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
        ),
        const Icon(Icons.chevron_right, size: 14, color: Colors.grey),
      ],
    );
  }

  Widget _buildCircleIconButton(IconData icon, VoidCallback onPressed) {
    return Container(
      margin: const EdgeInsets.all(4),
      decoration: const BoxDecoration(
        color: Colors.black26,
        shape: BoxShape.circle,
      ),
      child: IconButton(
        icon: Icon(icon, color: Colors.white, size: 20),
        onPressed: onPressed,
      ),
    );
  }

  // ---------------- 编辑资料悬浮窗 ----------------
  void _showEditSheet(BuildContext context, User user) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _EditProfileSheet(user: user, onSaved: _loadData),
    );
  }
}

class MockPostListTab extends StatefulWidget {
  final bool isDark;
  const MockPostListTab({super.key, required this.isDark});

  @override
  State<MockPostListTab> createState() => _MockPostListTabState();
}

class _MockPostListTabState extends State<MockPostListTab> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return ListView.builder(
      padding: const EdgeInsets.only(top: 8),
      itemCount: 20, // 增加到20以测试滚动保持
      itemBuilder: (context, index) {
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: widget.isDark ? const Color(0xFF1E1E1E).withOpacity(0.9) : Colors.white.withOpacity(0.95),
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.02),
                blurRadius: 10.0,
                offset: const Offset(0, 2),
              )
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '这是一个动态占位内容 $index',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                '这里是动态内容的摘要部分。在这个设计中，我们采用了贴吧风格的列表展示...',
                style: TextStyle(color: widget.isDark ? Colors.white70 : Colors.black87),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Icon(Icons.thumb_up_alt_outlined, size: 16, color: Colors.grey[500]),
                  const SizedBox(width: 4),
                  Text('12', style: TextStyle(color: Colors.grey[500], fontSize: 12)),
                  const SizedBox(width: 16),
                  Icon(Icons.chat_bubble_outline, size: 16, color: Colors.grey[500]),
                  const SizedBox(width: 4),
                  Text('4', style: TextStyle(color: Colors.grey[500], fontSize: 12)),
                ],
              )
            ],
          ),
        );
      },
    );
  }
}

class AnimatedCount extends StatelessWidget {
  final int count;
  final TextStyle style;

  const AnimatedCount({super.key, required this.count, required this.style});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: count.toDouble()),
      duration: const Duration(milliseconds: 800),
      curve: Curves.easeOutQuart,
      builder: (context, value, child) {
        return Text(
          value.toInt().toString(),
          style: style,
        );
      },
    );
  }
}

class _SliverAppBarDelegate extends SliverPersistentHeaderDelegate {
  _SliverAppBarDelegate(this._tabBar, this.backgroundColor);

  final TabBar _tabBar;
  final Color backgroundColor;

  @override
  double get minExtent => _tabBar.preferredSize.height;
  @override
  double get maxExtent => _tabBar.preferredSize.height;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    return Container(
      color: backgroundColor,
      child: _tabBar,
    );
  }

  bool shouldRebuild(_SliverAppBarDelegate oldDelegate) {
    return false;
  }
}

class _EditProfileSheet extends StatefulWidget {
  final User user;
  final VoidCallback onSaved;

  const _EditProfileSheet({required this.user, required this.onSaved});

  @override
  State<_EditProfileSheet> createState() => _EditProfileSheetState();
}

class _EditProfileSheetState extends State<_EditProfileSheet> {
  late TextEditingController _nicknameController;
  late String _selectedGender;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _nicknameController = TextEditingController(text: widget.user.nickname);
    _selectedGender = widget.user.gender.isEmpty ? 'male' : widget.user.gender;
  }

  @override
  void dispose() {
    _nicknameController.dispose();
    super.dispose();
  }

  Future<void> _pickAndUploadBackground() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.gallery);
    if (picked == null) return;

    if (!mounted) return;
    final auth = context.read<AuthProvider>();

    try {
      setState(() => _isSaving = true);
      // 复用 auth_provider 的图片上传接口 (也可以直接调 dio)
      FormData formData = FormData.fromMap({
        'file': await MultipartFile.fromFile(picked.path),
      });

      final uploadRes = await auth.dio.post('/upload', data: formData);
      if (uploadRes.statusCode == 200 && uploadRes.data['url'] != null) {
        final url = uploadRes.data['url'];
        // 更新背景
        await auth.dio.put('/user/background', data: {'background': url});
        
        // 更新本地状态
        await auth.refreshUser();
        widget.onSaved(); // 触发主页刷新
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('背景更换成功')));
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('上传失败: $e')));
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  Future<void> _saveProfile() async {
    final newNickname = _nicknameController.text.trim();
    if (newNickname.isEmpty) return;

    setState(() => _isSaving = true);
    try {
      final auth = context.read<AuthProvider>();
      await auth.dio.put('/user/profile', data: {
        'nickname': newNickname,
        'gender': _selectedGender,
      });

      await auth.refreshUser();
      widget.onSaved();
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('资料已保存')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('保存失败: $e')));
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    return Container(
      padding: EdgeInsets.only(
        left: 20, right: 20, top: 12,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 拖动条
          Container(
            width: 40, height: 4,
            decoration: BoxDecoration(
              color: Colors.grey.withOpacity(0.3),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 20),
          Text('编辑资料', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: isDark ? Colors.white : Colors.black87)),
          const SizedBox(height: 24),
          
          // 更改背景
          InkWell(
            onTap: _isSaving ? null : _pickAndUploadBackground,
            borderRadius: BorderRadius.circular(12),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
              decoration: BoxDecoration(
                color: isDark ? Colors.grey[800] : Colors.grey[100],
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  const Icon(Icons.image, color: Colors.blue),
                  const SizedBox(width: 12),
                  const Expanded(child: Text('更改主页背景图')),
                  Icon(Icons.chevron_right, color: Colors.grey[500]),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // 昵称
          TextField(
            controller: _nicknameController,
            decoration: InputDecoration(
              labelText: '昵称',
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              prefixIcon: const Icon(Icons.person_outline),
            ),
          ),
          const SizedBox(height: 16),

          // 性别
          Row(
            children: [
              const Text('性别: ', style: TextStyle(fontSize: 16)),
              const SizedBox(width: 16),
              Expanded(
                child: SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'male', label: Text('男生'), icon: Icon(Icons.male)),
                    ButtonSegment(value: 'female', label: Text('女生'), icon: Icon(Icons.female)),
                    ButtonSegment(value: '', label: Text('保密')),
                  ],
                  selected: {_selectedGender},
                  onSelectionChanged: (Set<String> newSelection) {
                    setState(() {
                      _selectedGender = newSelection.first;
                    });
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),

          // 保存按钮
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _isSaving ? null : _saveProfile,
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: _isSaving 
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('保存', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image_cropper/image_cropper.dart';
import '../providers/auth_provider.dart';
import '../config/api_constants.dart';
import '../models/user.dart';
import '../models/post.dart';
import '../providers/social_provider.dart';
import '../widgets/post_card.dart';
import '../widgets/cached_avatar.dart';
import 'social_list_screen.dart';
import 'image_viewer_screen.dart';
import 'chat_detail_screen.dart';

class UserHomeScreen extends StatefulWidget {
  final int? userId;
  const UserHomeScreen({super.key, this.userId});

  @override
  State<UserHomeScreen> createState() => _UserHomeScreenState();
}

class _UserHomeScreenState extends State<UserHomeScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final ScrollController _scrollController = ScrollController();
  User? _user;
  List<Post> _posts = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    if (widget.userId == null) {
      _user = context.read<AuthProvider>().user;
    }
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

    if (_user == null) {
      if (_isLoading) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      return Scaffold(
        appBar: AppBar(title: const Text('错误')),
        body: const Center(child: Text('用户不存在或加载失败')),
      );
    }

    final user = _user!;
    final isMe =
        widget.userId == null ||
        widget.userId == context.read<AuthProvider>().user?.id;

    final pageBackground = isDark
        ? const Color(0xFF111214)
        : Theme.of(context).scaffoldBackgroundColor;

    // 标签栏和内容区共用的面板色
    final panelColor = isDark ? const Color(0xFF1A1B1E) : Colors.white;

    final screenWidth = MediaQuery.sizeOf(context).width;
    final heroHeight = (screenWidth * 1.03).clamp(390.0, 480.0);

    return Scaffold(
      backgroundColor: panelColor,
      body: RefreshIndicator(
        onRefresh: () async {
          await _loadData();
        },
        child: NestedScrollView(
          controller: _scrollController,
          headerSliverBuilder: (BuildContext context, bool innerBoxIsScrolled) {
            return <Widget>[
              SliverAppBar(
                expandedHeight: heroHeight,
                pinned: true,
                floating: false,
                elevation: 0,
                scrolledUnderElevation: 0,
                surfaceTintColor: Colors.transparent,
                backgroundColor: pageBackground,
                toolbarHeight: 0,
                automaticallyImplyLeading: false,
                flexibleSpace: FlexibleSpaceBar(
                  collapseMode: CollapseMode.parallax,
                  background: Stack(
                    fit: StackFit.expand,
                    children: [
                      // 背景图
                      GestureDetector(
                        onTap: isMe
                            ? () => _showEditSheet(context, user)
                            : null,
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

                      // 下部渐暗遮罩
                      const DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            stops: [0.0, 0.42, 1.0],
                            colors: [
                              Colors.transparent,
                              Color(0x22000000),
                              Color(0xDD000000),
                            ],
                          ),
                        ),
                      ),

                      // 顶部按钮行（返回 + 私信）
                      Positioned(
                        top: MediaQuery.of(context).padding.top + 8,
                        left: 12,
                        right: 12,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            _buildCircleButton(
                              icon: Icons.arrow_back,
                              onTap: () => Navigator.maybePop(context),
                            ),
                            if (!isMe)
                              _buildCircleButton(
                                icon: Icons.mail_outline,
                                onTap: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) =>
                                          ChatDetailScreen(targetUser: user),
                                    ),
                                  );
                                },
                              ),
                          ],
                        ),
                      ),

                      // 所有资料覆盖在背景图下半部分
                      Positioned(
                        left: 20,
                        right: 20,
                        bottom: 64,
                        child: _buildProfileOverlay(context, user, isMe),
                      ),
                    ],
                  ),
                ),

                // 底部圆角标签栏
                bottom: PreferredSize(
                  preferredSize: const Size.fromHeight(46),
                  child: Container(
                    height: 46,
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: panelColor,
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(22),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.08),
                          blurRadius: 8,
                          offset: const Offset(0, -2),
                        ),
                      ],
                    ),
                    child: TabBar(
                      controller: _tabController,
                      indicatorSize: TabBarIndicatorSize.label,
                      indicatorWeight: 3,
                      indicatorColor: Theme.of(context).colorScheme.primary,
                      labelColor: Theme.of(context).colorScheme.primary,
                      unselectedLabelColor: isDark
                          ? Colors.white60
                          : Colors.black54,
                      labelStyle: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                      unselectedLabelStyle: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                      tabs: [
                        Tab(text: '帖子 ${_posts.length}'),
                        const Tab(text: '智能体 0'),
                      ],
                    ),
                  ),
                ),
              ),
            ];
          },
          body: TabBarView(
            controller: _tabController,
            children: [
              _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _posts.isEmpty
                  ? const Center(child: Text('暂无帖子'))
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
                      itemCount: _posts.length,
                      itemBuilder: (context, index) {
                        return PostCard(
                          post: _posts[index],
                          disableAuthorNavigation: true,
                        );
                      },
                    ),
              const Center(child: Text('暂无智能体')),
            ],
          ),
        ),
      ),
    );
  }

  // ============ 顶部圆形按钮 ============

  Widget _buildCircleButton({
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 36,
        height: 36,
        decoration: const BoxDecoration(
          color: Colors.black26,
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: Colors.white, size: 20),
      ),
    );
  }

  // ============ 覆盖在背景上的个人资料 ============

  Widget _buildProfileOverlay(BuildContext context, User user, bool isMe) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // 第一行：头像 + 编辑/关注按钮
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            GestureDetector(
              onTap: () {
                if (user.avatar.isNotEmpty) {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ImageViewerScreen(
                        imageUrls: [ApiConstants.fullUrl(user.avatar)],
                      ),
                    ),
                  );
                }
              },
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.9),
                    width: 2,
                  ),
                ),
                child: CachedAvatar(
                  imageUrl: user.avatar.isNotEmpty
                      ? ApiConstants.fullUrl(user.avatar)
                      : null,
                  radius: 38,
                  fallbackText: user.nickname,
                ),
              ),
            ),
            const Spacer(),
            if (isMe)
              _buildOverlayButton(
                text: '编辑资料',
                onPressed: () => _showEditSheet(context, user),
              )
            else
              _buildFollowButton(context, user),
          ],
        ),

        // 第二行：昵称 + 等级
        const SizedBox(height: 16),
        Row(
          children: [
            Flexible(
              child: Text(
                user.nickname,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
              decoration: BoxDecoration(
                color: Color(user.levelColorValue),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                user.levelLabel,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),

        // 第三行：性别、ID、学院
        const SizedBox(height: 8),
        Row(
          children: [
            Icon(
              user.gender == 'female' ? Icons.female : Icons.male,
              size: 15,
              color: user.gender == 'female'
                  ? Colors.pinkAccent
                  : Colors.lightBlueAccent,
            ),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                'ID ${user.studentId}  ${user.eduCollege.isNotEmpty ? user.eduCollege : '未知归属'}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ),
          ],
        ),

        // 统计数据：获赞、关注、粉丝
        const SizedBox(height: 14),
        Row(
          children: [
            _buildOverlayStat(user.totalLikesReceived.toString(), '获赞', null),
            const SizedBox(width: 28),
            _buildOverlayStat(
              user.followingCount.toString(),
              '关注',
              isMe
                  ? () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => SocialListScreen(
                            userId: user.id,
                            initialIndex: 0,
                          ),
                        ),
                      );
                    }
                  : null,
            ),
            const SizedBox(width: 28),
            _buildOverlayStat(
              user.followersCount.toString(),
              '粉丝',
              isMe
                  ? () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => SocialListScreen(
                            userId: user.id,
                            initialIndex: 1,
                          ),
                        ),
                      );
                    }
                  : null,
            ),
          ],
        ),

        // 等级进度 + 积分半透明条
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
          ),
          child: Row(
            children: [
              Text(
                user.levelLabel,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: user.levelProgress,
                    minHeight: 6,
                    backgroundColor: Colors.white24,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      Color(user.levelColorValue),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '${user.exp}/${user.expToNextLevel}',
                style: const TextStyle(color: Colors.white70, fontSize: 11),
              ),
              const SizedBox(width: 14),
              const Icon(Icons.monetization_on, color: Colors.amber, size: 16),
              const SizedBox(width: 4),
              Text(
                '${user.credits}',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ============ 覆盖层辅助组件 ============

  Widget _buildOverlayButton({
    required String text,
    required VoidCallback onPressed,
  }) {
    return Material(
      color: Colors.white.withValues(alpha: 0.18),
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(22),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
          child: Text(
            text,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFollowButton(BuildContext context, User user) {
    if (user.isFollowing) {
      return _buildOverlayButton(
        text: '已关注',
        onPressed: () async {
          final success = await context.read<SocialProvider>().unfollow(
            user.id,
          );
          if (success && mounted) {
            setState(() {
              _user!.isFollowing = false;
              _user!.followersCount = (_user!.followersCount - 1).clamp(
                0,
                999999,
              );
            });
            context.read<AuthProvider>().refreshUser();
          }
        },
      );
    } else {
      return Material(
        color: Theme.of(context).colorScheme.primary,
        borderRadius: BorderRadius.circular(22),
        child: InkWell(
          onTap: () async {
            final success = await context.read<SocialProvider>().follow(
              user.id,
            );
            if (success && mounted) {
              setState(() {
                _user!.isFollowing = true;
                _user!.followersCount++;
              });
              context.read<AuthProvider>().refreshUser();
            }
          },
          borderRadius: BorderRadius.circular(22),
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 22, vertical: 9),
            child: Text(
              '关注',
              style: TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      );
    }
  }

  Widget _buildOverlayStat(String count, String label, VoidCallback? onTap) {
    return InkWell(
      onTap: onTap,
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: count,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
            TextSpan(
              text: ' $label',
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------- 编辑资料悬浮窗 ----------------
  void _showEditSheet(BuildContext context, User user) {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        child: _EditProfileSheet(user: user, onSaved: _loadData),
      ),
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
        return Text(value.toInt().toString(), style: style);
      },
    );
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

    final cropped = await ImageCropper().cropImage(
      sourcePath: picked.path,
      aspectRatio: const CropAspectRatio(ratioX: 3, ratioY: 4),
      uiSettings: [
        AndroidUiSettings(
          toolbarTitle: '裁剪背景图',
          toolbarColor: Colors.black,
          toolbarWidgetColor: Colors.white,
          statusBarColor: Colors.black,
          backgroundColor: Colors.black,
          initAspectRatio: CropAspectRatioPreset.ratio3x2,
          lockAspectRatio: true,
        ),
        IOSUiSettings(title: '裁剪背景图', aspectRatioLockEnabled: true),
      ],
    );

    if (cropped == null) return;

    if (!mounted) return;
    final auth = context.read<AuthProvider>();

    try {
      setState(() => _isSaving = true);
      final croppedBytes = await cropped.readAsBytes();
      final croppedName =
          'background_${DateTime.now().millisecondsSinceEpoch}.jpg';
      FormData formData = FormData.fromMap({
        'file': MultipartFile.fromBytes(croppedBytes, filename: croppedName),
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
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('背景更换成功')));
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('上传失败: $e')));
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
      await auth.dio.put(
        '/user/profile',
        data: {'nickname': newNickname, 'gender': _selectedGender},
      );

      await auth.refreshUser();
      widget.onSaved();
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('资料已保存')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('保存失败: $e')));
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
        left: 20,
        right: 20,
        top: 12,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 20,
            spreadRadius: 5,
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 拖动条
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey.withOpacity(0.3),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            '编辑资料',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: isDark ? Colors.white : Colors.black87,
            ),
          ),
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
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
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
                    ButtonSegment(
                      value: 'male',
                      label: Text('男生'),
                      icon: Icon(Icons.male),
                    ),
                    ButtonSegment(
                      value: 'female',
                      label: Text('女生'),
                      icon: Icon(Icons.female),
                    ),
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
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: _isSaving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text(
                      '保存',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

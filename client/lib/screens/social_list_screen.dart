import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/social_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/post_provider.dart';
import '../models/user.dart';
import 'user_home_screen.dart';
import '../config/api_constants.dart';
import '../widgets/cached_avatar.dart';

class SocialListScreen extends StatefulWidget {
  final int userId;
  final int initialIndex; // 0: 关注, 1: 粉丝

  const SocialListScreen({
    super.key,
    required this.userId,
    this.initialIndex = 0,
  });

  @override
  State<SocialListScreen> createState() => _SocialListScreenState();
}

class _SocialListScreenState extends State<SocialListScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 2,
      vsync: this,
      initialIndex: widget.initialIndex,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('关注与粉丝'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: '关注'),
            Tab(text: '粉丝'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _UserList(userId: widget.userId, type: 'following'),
          _UserList(userId: widget.userId, type: 'followers'),
        ],
      ),
    );
  }
}

class _UserList extends StatefulWidget {
  final int userId;
  final String type;

  const _UserList({required this.userId, required this.type});

  @override
  State<_UserList> createState() => _UserListState();
}

class _UserListState extends State<_UserList> {
  static final Map<String, List<User>> _usersCache = {};
  static final Map<String, int> _pageCache = {};
  static final Map<String, bool> _hasMoreCache = {};

  int? _viewerId;
  int _sessionEpoch = -1;
  String? _errorMessage;

  String get _cacheKey => '${_viewerId ?? 0}_${widget.userId}_${widget.type}';

  List<User> _users = [];
  bool _isLoading = true;
  bool _hasMore = true;
  int _page = 1;
  bool _isFetching = false;

  @override
  void initState() {
    super.initState();
  }

  void _syncSessionScope(AuthProvider auth) {
    if (_sessionEpoch == auth.accountSessionEpoch) return;

    _sessionEpoch = auth.accountSessionEpoch;
    _viewerId = auth.user?.id;
    _users = List.from(_usersCache[_cacheKey] ?? const <User>[]);
    _page = _pageCache[_cacheKey] ?? 1;
    _hasMore = _hasMoreCache[_cacheKey] ?? true;
    _errorMessage = null;
    _isLoading = _users.isEmpty;
    _isFetching = false;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _loadData(refresh: _users.isNotEmpty, silent: _users.isNotEmpty);
    });
  }

  Future<void> _loadData({bool refresh = false, bool silent = false}) async {
    if (_isFetching) return;
    if (refresh) {
      if (!silent) {
        setState(() {
          _page = 1;
          _hasMore = true;
          _isLoading = true;
        });
      } else {
        _page = 1;
        _hasMore = true;
      }
    }

    if (!_hasMore) return;
    _isFetching = true;

    final provider = context.read<SocialProvider>();
    final auth = context.read<AuthProvider>();
    final requestEpoch = auth.accountSessionEpoch;
    final requestViewerId = auth.user?.id;
    try {
      Map<String, dynamic> result;
      if (widget.type == 'following') {
        result = await provider.getFollowing(widget.userId, page: _page);
      } else {
        result = await provider.getFollowers(widget.userId, page: _page);
      }

      if (!mounted ||
          auth.accountSessionEpoch != requestEpoch ||
          auth.user?.id != requestViewerId) {
        return;
      }

      final items = result['items'] as List<dynamic>? ?? [];
      final total = (result['total'] as num?)?.toInt() ?? 0;
      final loadedUsers = items
          .whereType<Map>()
          .map((e) => User.fromJson(Map<String, dynamic>.from(e)))
          .toList();

      setState(() {
        _errorMessage = null;
        if (refresh) {
          _users = loadedUsers;
        } else {
          // Add basic deduplication check to prevent edge-case duplicate inserts
          for (final loadedUser in loadedUsers) {
            if (!_users.any((u) => u.id == loadedUser.id)) {
              _users.add(loadedUser);
            }
          }
        }
        _isLoading = false;
        _isFetching = false;
        if (_users.length >= total || loadedUsers.isEmpty) {
          _hasMore = false;
        } else {
          _page++;
        }

        _usersCache[_cacheKey] = _users;
        _pageCache[_cacheKey] = _page;
        _hasMoreCache[_cacheKey] = _hasMore;
      });
    } on SocialRequestException catch (error) {
      if (!mounted || error.sessionChanged) return;
      setState(() {
        _errorMessage = error.message;
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = '加载列表失败，请稍后重试';
        _isLoading = false;
      });
    } finally {
      if (mounted) {
        final currentAuth = context.read<AuthProvider>();
        if (currentAuth.accountSessionEpoch == requestEpoch &&
            currentAuth.user?.id == requestViewerId) {
          _isFetching = false;
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    _syncSessionScope(auth);

    if (_isLoading && _users.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_errorMessage != null && _users.isEmpty) {
      return _buildErrorState();
    }

    if (_users.isEmpty) {
      return RefreshIndicator(
        onRefresh: () => _loadData(refresh: true),
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverFillRemaining(
              child: Center(
                child: Text(
                  widget.type == 'following' ? '暂无关注' : '暂无粉丝',
                  style: const TextStyle(color: Colors.grey),
                ),
              ),
            ),
          ],
        ),
      );
    }

    final currentUserId = auth.user?.id;

    return RefreshIndicator(
      onRefresh: () => _loadData(refresh: true),
      child: ListView.builder(
        itemCount: _users.length + (_hasMore && !_isLoading ? 1 : 0),
        itemBuilder: (context, index) {
          if (index == _users.length) {
            _loadData();
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(8.0),
                child: CircularProgressIndicator(),
              ),
            );
          }

          final user = _users[index];
          final isMe = currentUserId == user.id;

          return ListTile(
            leading: CachedAvatar(
              imageUrl: user.avatar.isNotEmpty
                  ? ApiConstants.fullUrl(user.avatar)
                  : null,
              radius: 20,
              fallbackText:
                  user.nickname.isNotEmpty ? user.nickname : '用户${user.id}',
            ),
            title: Text(
              user.nickname.isNotEmpty ? user.nickname : '用户${user.id}',
            ),
            subtitle: Text('Lv.${user.level}'),
            trailing: isMe ? null : _buildFollowButton(user),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => UserHomeScreen(userId: user.id),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildErrorState() {
    return RefreshIndicator(
      onRefresh: () => _loadData(refresh: true),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(
            height: 260,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.cloud_off, color: Colors.grey, size: 42),
                  const SizedBox(height: 12),
                  Text(_errorMessage!,
                      style: const TextStyle(color: Colors.grey)),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: _loadData,
                    child: const Text('重试'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFollowButton(User user) {
    return OutlinedButton(
      onPressed: () async {
        final provider = context.read<SocialProvider>();
        bool success = false;
        if (user.isFollowing) {
          success = await provider.unfollow(user.id);
        } else {
          success = await provider.follow(user.id);
        }
        if (success && mounted) {
          setState(() {
            user.isFollowing = !user.isFollowing;
          });
          // Refresh global user state so profile follow count updates instantly
          context.read<AuthProvider>().refreshUser();
          context.read<PostProvider>().invalidateFollowingFeed();
        }
      },
      child: Text(user.isFollowing ? '已关注' : '关注'),
    );
  }
}

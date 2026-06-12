import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/social_provider.dart';
import '../providers/auth_provider.dart';
import '../models/user.dart';
import 'user_home_screen.dart';

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

class _SocialListScreenState extends State<SocialListScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this, initialIndex: widget.initialIndex);
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
  List<User> _users = [];
  bool _isLoading = true;
  bool _hasMore = true;
  int _page = 1;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData({bool refresh = false}) async {
    if (refresh) {
      setState(() {
        _page = 1;
        _hasMore = true;
        _isLoading = true;
      });
    }

    if (!_hasMore) return;

    final provider = context.read<SocialProvider>();
    Map<String, dynamic> result;
    if (widget.type == 'following') {
      result = await provider.getFollowing(widget.userId, page: _page);
    } else {
      result = await provider.getFollowers(widget.userId, page: _page);
    }

    final items = result['items'] as List<dynamic>? ?? [];
    final total = result['total'] as int? ?? 0;
    
    final List<User> loadedUsers = items.map((e) => User.fromJson(e)).toList();

    if (mounted) {
      setState(() {
        if (refresh) {
          _users = loadedUsers;
        } else {
          _users.addAll(loadedUsers);
        }
        _isLoading = false;
        if (_users.length >= total || loadedUsers.isEmpty) {
          _hasMore = false;
        } else {
          _page++;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading && _users.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_users.isEmpty) {
      return Center(
        child: Text(widget.type == 'following' ? '暂无关注' : '暂无粉丝',
            style: const TextStyle(color: Colors.grey)),
      );
    }

    final currentUserId = context.read<AuthProvider>().user?.id;

    return RefreshIndicator(
      onRefresh: () => _loadData(refresh: true),
      child: ListView.builder(
        itemCount: _users.length + (_hasMore ? 1 : 0),
        itemBuilder: (context, index) {
          if (index == _users.length) {
            _loadData();
            return const Center(child: Padding(
              padding: EdgeInsets.all(8.0),
              child: CircularProgressIndicator(),
            ));
          }

          final user = _users[index];
          final isMe = currentUserId == user.id;

          return ListTile(
            leading: CircleAvatar(
              backgroundImage: user.avatar.isNotEmpty ? NetworkImage(user.avatar) : null,
              child: user.avatar.isEmpty ? const Icon(Icons.person) : null,
            ),
            title: Text(user.nickname.isNotEmpty ? user.nickname : '用户${user.id}'),
            subtitle: Text('Lv.${user.level}'),
            trailing: isMe ? null : _buildFollowButton(user),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => UserHomeScreen(userId: user.id)),
              );
            },
          );
        },
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
        if (success) {
           setState(() {
             user.isFollowing = !user.isFollowing;
           });
        }
      },
      child: Text(user.isFollowing ? '已关注' : '关注'),
    );
  }
}

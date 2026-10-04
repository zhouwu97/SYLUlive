import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../widgets/cached_avatar.dart';
import '../utils/app_time.dart';
import 'post_detail_screen.dart';
import 'user_home_screen.dart';

class LikesReceivedScreen extends StatefulWidget {
  const LikesReceivedScreen({super.key});
  @override
  State<LikesReceivedScreen> createState() => _LikesReceivedScreenState();
}

class _LikesReceivedScreenState extends State<LikesReceivedScreen> {
  AuthProvider? _auth;
  int? _accountId;
  int _epoch = -1;
  int _generation = 0;
  List<Map<String, dynamic>> _items = [];
  bool _loading = false;
  bool _hasMore = false;
  String _cursor = '';
  String? _error;
  bool _retryMore = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final auth = context.read<AuthProvider>();
    if (_auth != auth) {
      _auth?.removeListener(_syncAccount);
      _auth = auth;
      auth.addListener(_syncAccount);
    }
    _syncAccount();
  }

  void _syncAccount() {
    final auth = _auth!;
    if (_accountId == auth.user?.id && _epoch == auth.accountSessionEpoch) {
      return;
    }
    _accountId = auth.user?.id;
    _epoch = auth.accountSessionEpoch;
    _generation++;
    _items = [];
    _cursor = '';
    _hasMore = false;
    _error = null;
    _loading = false;
    if (mounted) setState(() {});
    if (auth.isLoggedIn) _load();
  }

  Future<void> _load({bool more = false}) async {
    final auth = _auth!;
    if (_loading || !auth.isLoggedIn) return;
    final generation = _generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final response =
          await auth.dio.get('/user/likes/received', queryParameters: {
        'limit': 30,
        if (more && _cursor.isNotEmpty) 'cursor': _cursor,
      });
      if (!mounted || generation != _generation) return;
      if (response.statusCode != 200 || response.data is! Map) {
        throw StateError('invalid response');
      }
      final data = Map<String, dynamic>.from(response.data as Map);
      final items = (data['items'] as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      setState(() {
        _items = more ? [..._items, ...items] : items;
        _cursor = data['next_cursor'] as String? ?? '';
        _hasMore = data['has_more'] == true && _cursor.isNotEmpty;
      });
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() {
          _error = '收到的赞加载失败，请重试';
          _retryMore = more;
        });
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  void dispose() {
    _generation++;
    _auth?.removeListener(_syncAccount);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('收到的赞')),
      body: !(_auth?.isLoggedIn ?? false)
          ? const Center(child: Text('请先登录后查看收到的赞'))
          : _loading && _items.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(16),
                    children: [
                      if (_error != null)
                        ListTile(
                          title: Text(_error!),
                          trailing: TextButton(
                              onPressed: () => _load(more: _retryMore),
                              child: const Text('重试')),
                        ),
                      if (_items.isEmpty && _error == null)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 80),
                          child: Center(child: Text('暂时没有收到其他人的赞')),
                        ),
                      for (final item in _items) _buildItem(item),
                      if (_loading)
                        const Center(child: CircularProgressIndicator()),
                      if (_hasMore && !_loading && _error == null)
                        TextButton(
                            onPressed: () => _load(more: true),
                            child: const Text('加载更多')),
                    ],
                  ),
                ),
    );
  }

  Widget _buildItem(Map<String, dynamic> item) {
    final name = item['nickname'] as String? ?? '用户';
    final date = DateTime.tryParse(item['created_at']?.toString() ?? '');
    final time = date == null ? null : AppTime.toShanghai(date);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: IconButton(
        tooltip: '查看$name的主页',
        icon: CachedAvatar(
            imageUrl: item['avatar'] as String?, fallbackText: name),
        onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => UserHomeScreen(userId: item['user_id'] as int))),
      ),
      title: Text('$name 赞了你的${item['target_type'] == 'reply' ? '评论' : '帖子'}'),
      subtitle: Text(
          '${item['post_title'] ?? ''}${time == null ? '' : '\n${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')} ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}'}'),
      isThreeLine: time != null,
      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => PostDetailScreen(
                postId: item['post_id'] as int,
                targetReplyId: item['target_type'] == 'reply'
                    ? item['target_id'] as int
                    : null,
              ))),
    );
  }
}

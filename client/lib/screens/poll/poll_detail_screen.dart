import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../config/api_constants.dart';
import '../../models/post.dart';
import '../../models/reply.dart';
import '../../providers/auth_provider.dart';
import '../../providers/poll_provider.dart';
import '../../providers/post_provider.dart';
import '../../services/poll_service.dart';
import '../../utils/app_feedback.dart';
import '../../widgets/cached_avatar.dart';
import '../../widgets/poll/poll_post_card.dart';
import '../../widgets/report_sheet.dart';
import '../user_home_screen.dart';
import 'poll_composer_screen.dart';

class PollDetailScreen extends StatefulWidget {
  final int pollId;
  final Post? initialPost;
  final bool isDesktopSplitMode;
  final bool hideBackButton;
  final ValueChanged<int>? onAuthorTap;

  const PollDetailScreen({super.key, required this.pollId, this.initialPost, this.isDesktopSplitMode = false, this.hideBackButton = false, this.onAuthorTap});

  @override
  State<PollDetailScreen> createState() => _PollDetailScreenState();
}

class _PollDetailScreenState extends State<PollDetailScreen> {
  Post? _post;
  List<Reply> _replies = [];
  final _replyController = TextEditingController();
  bool _loading = true;
  bool _sending = false;
  bool _liked = false;
  int _likeCount = 0;
  late final PollService _service;

  @override
  void initState() {
    super.initState();
    _post = widget.initialPost;
    _service = PollService(context.read<AuthProvider>().dio);
    _load();
  }

  @override
  void dispose() { _replyController.dispose(); super.dispose(); }

  Future<void> _load() async {
    try {
      final post = await _service.getPoll(widget.pollId);
      final response = await context.read<AuthProvider>().dio.get('/posts/${post.id}/replies');
      if (!mounted) return;
      setState(() { _post = post.copyWith(replyCount: (response.data as List).length); _replies = (response.data as List).map((e) => Reply.fromJson(e)).toList(); _liked = post.isLiked; _likeCount = post.likeCount; _loading = false; });
      context.read<PollProvider>().applyExternalPostUpdate(_post!);
      context.read<PostProvider>().applyExternalPostUpdate(_post!);
    } on DioException catch (error) { if (mounted) setState(() => _loading = false); if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(AppFeedback.dioErrorMessage(error, fallback: '加载投票失败')))); }
    catch (_) { if (mounted) setState(() => _loading = false); }
  }

  Future<void> _sendReply() async {
    final text = _replyController.text.trim();
    if (text.isEmpty || _sending || !context.read<AuthProvider>().isLoggedIn) return;
    setState(() => _sending = true);
    try {
      final response = await context.read<AuthProvider>().dio.post('/posts/${_post!.id}/replies', data: FormData.fromMap({'content': text}));
      if (mounted) { setState(() { _replies.insert(0, Reply.fromJson(response.data)); _replyController.clear(); _post = _post!.copyWith(replyCount: _replies.length); }); context.read<PostProvider>().applyExternalPostUpdate(_post!); }
    } on DioException catch (error) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(AppFeedback.dioErrorMessage(error, fallback: '评论失败')))); }
    finally { if (mounted) setState(() => _sending = false); }
  }

  Future<void> _toggleLike() async {
    if (!context.read<AuthProvider>().isLoggedIn || _post == null) return;
    final next = !_liked; setState(() { _liked = next; _likeCount += next ? 1 : -1; });
    try { if (next) { await context.read<AuthProvider>().dio.post('/posts/${_post!.id}/like'); } else { await context.read<AuthProvider>().dio.delete('/posts/${_post!.id}/like'); } } catch (_) { if (mounted) setState(() { _liked = !next; _likeCount += next ? -1 : 1; }); }
    if (mounted) { _post = _post!.copyWith(isLiked: _liked, likeCount: _likeCount); context.read<PostProvider>().applyExternalPostUpdate(_post!); context.read<PollProvider>().applyExternalPostUpdate(_post!); }
  }

  Future<void> _edit() async {
    if (_post == null) return;
    final result = await Navigator.push(context, MaterialPageRoute(builder: (_) => PollComposerScreen(editingPost: _post)));
    if (result == true && mounted) _load();
  }

  Future<void> _delete() async {
    if (_post == null) return;
    final yes = await showDialog<bool>(context: context, builder: (context) => AlertDialog(title: const Text('删除投票？'), content: const Text('删除后不可恢复。'), actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')), FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('删除'))])) ?? false;
    if (!yes || !mounted) return;
    if (await context.read<PollProvider>().deletePoll(widget.pollId)) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final post = _post;
    if (_loading && post == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (post == null) return const Scaffold(body: Center(child: Text('投票不存在或已删除')));
    final poll = post.pollMeta!;
    return Scaffold(
      appBar: widget.hideBackButton ? null : AppBar(title: const Text('投票详情'), actions: [PopupMenuButton<String>(onSelected: (value) { if (value == 'edit') _edit(); if (value == 'close') context.read<PollProvider>().closePoll(poll.id); if (value == 'delete') _delete(); if (value == 'report') showReportSheet(context, targetId: post.id); }, itemBuilder: (_) => [if (poll.isOwner) const PopupMenuItem(value: 'edit', child: Text('编辑说明')), if (poll.isOwner && poll.isActive) const PopupMenuItem(value: 'close', child: Text('提前结束')), if (poll.isOwner) const PopupMenuItem(value: 'delete', child: Text('删除')), if (!poll.isOwner) const PopupMenuItem(value: 'report', child: Text('举报'))])]),
      body: RefreshIndicator(onRefresh: _load, child: ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 90), children: [
        const Text('非官方用户投票，结果仅代表参与用户的选择。', style: TextStyle(fontSize: 12, color: Colors.black54)),
        const SizedBox(height: 8),
        PollPostCard(post: post, variant: PollCardVariant.centerFull, onAuthorTap: widget.onAuthorTap ?? (id) => Navigator.push(context, MaterialPageRoute(builder: (_) => UserHomeScreen(userId: id)))),
        Row(children: [IconButton(onPressed: _toggleLike, icon: Icon(_liked ? Icons.thumb_up : Icons.thumb_up_outlined)), Text('$_likeCount'), const SizedBox(width: 20), const Icon(Icons.chat_bubble_outline, size: 20), const SizedBox(width: 4), Text('${_replies.length}')]),
        const Divider(height: 24),
        Text('评论 ${_replies.length}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        ..._replies.map((reply) => ListTile(leading: CachedAvatar(radius: 16, imageUrl: reply.author?.avatar.isNotEmpty == true ? ApiConstants.fullUrl(reply.author!.avatar) : null, fallbackText: reply.author?.nickname ?? '用户'), title: Text(reply.author?.nickname ?? '用户'), subtitle: Text(reply.content), dense: true)),
      ])),
      bottomNavigationBar: SafeArea(child: Padding(padding: const EdgeInsets.fromLTRB(12, 6, 12, 8), child: Row(children: [Expanded(child: TextField(controller: _replyController, textInputAction: TextInputAction.send, onSubmitted: (_) => _sendReply(), decoration: const InputDecoration(hintText: '说点什么…', border: OutlineInputBorder()))), const SizedBox(width: 8), IconButton(onPressed: _sending ? null : _sendReply, icon: const Icon(Icons.send))]))),
    );
  }
}

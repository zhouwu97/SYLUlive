import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/post.dart';
import '../../providers/poll_provider.dart';
import '../../screens/poll/poll_composer_screen.dart';
import '../../widgets/community_post_card.dart';
import '../../widgets/poll/poll_post_card.dart';
import 'poll_detail_screen.dart';

class MyPollsScreen extends StatefulWidget {
  const MyPollsScreen({super.key});

  @override
  State<MyPollsScreen> createState() => _MyPollsScreenState();
}

class _MyPollsScreenState extends State<MyPollsScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  String get _scope => _tabs.index == 0 ? 'created' : 'participated';

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _tabs.addListener(() { if (!_tabs.indexIsChanging) { setState(() {}); _load(); } });
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load({bool refresh = false}) => context.read<PollProvider>().loadMine(_scope, refresh: refresh);

  @override
  void dispose() { _tabs.dispose(); super.dispose(); }

  Future<void> _edit(Post post) async {
    final updated = await Navigator.push(context, MaterialPageRoute(builder: (_) => PollComposerScreen(editingPost: post)));
    if (updated == true && mounted) _load(refresh: true);
  }

  Future<void> _delete(Post post) async {
    final pollId = post.pollMeta!.id;
    final ok = await showDialog<bool>(context: context, builder: (context) => AlertDialog(title: const Text('删除投票？'), content: const Text('删除后不可恢复。'), actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')), FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('删除'))])) ?? false;
    if (ok && mounted) { await context.read<PollProvider>().deletePoll(pollId); }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<PollProvider>();
    final state = provider.mineState(_scope);
    return Scaffold(
      appBar: AppBar(title: const Text('我的投票'), bottom: TabBar(controller: _tabs, tabs: const [Tab(text: '我发起的'), Tab(text: '我参与的')])),
      body: RefreshIndicator(
        onRefresh: () => _load(refresh: true),
        child: state.isLoading && !state.hasLoaded
            ? const Center(child: CircularProgressIndicator())
            : ListView.builder(
                key: PageStorageKey('my-polls-$_scope'),
                padding: const EdgeInsets.all(12),
                itemCount: state.items.length + (state.isLoadingMore ? 1 : 0),
                itemBuilder: (context, index) {
                  if (index >= state.items.length) return const Center(child: CircularProgressIndicator());
                  final post = state.items[index];
                  return Column(children: [
                    CommunityPostCard(post: post, pollVariant: PollCardVariant.centerFull, onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => PollDetailScreen(pollId: post.pollMeta!.id, initialPost: post)))),
                    if (_scope == 'created') Row(mainAxisAlignment: MainAxisAlignment.end, children: [TextButton.icon(onPressed: post.pollMeta!.isActive ? () => context.read<PollProvider>().closePoll(post.pollMeta!.id) : null, icon: const Icon(Icons.stop_circle_outlined), label: const Text('结束')), TextButton.icon(onPressed: () => _edit(post), icon: const Icon(Icons.edit_outlined), label: const Text('编辑')), TextButton.icon(onPressed: () => _delete(post), icon: const Icon(Icons.delete_outline), label: const Text('删除'))]),
                  ]);
                },
              ),
      ),
    );
  }
}

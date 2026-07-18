import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/post.dart';
import '../../providers/poll_provider.dart';
import '../../widgets/community_post_card.dart';
import '../../widgets/poll/poll_post_card.dart';
import 'my_polls_screen.dart';
import 'poll_detail_screen.dart';

class PollCenterScreen extends StatefulWidget {
  final String initialSort;

  const PollCenterScreen({super.key, this.initialSort = 'recommend'});

  @override
  State<PollCenterScreen> createState() => _PollCenterScreenState();
}

class _PollCenterScreenState extends State<PollCenterScreen>
    with SingleTickerProviderStateMixin {
  static const _sorts = <String, String>{
    'recommend': '推荐',
    'latest': '最新',
    'ending': '即将结束',
  };
  static const _categories = <String, String>{
    'all': '全部',
    'campus_life': '校园生活',
    'study': '学习',
    'activity': '活动',
    'other': '其他',
  };

  late String _sort;
  String _category = 'all';
  late final TabController _tabController;
  final _scrollControllers = <String, ScrollController>{};

  @override
  void initState() {
    super.initState();
    _sort = _sorts.containsKey(widget.initialSort) ? widget.initialSort : 'recommend';
    _tabController = TabController(length: _sorts.length, vsync: this, initialIndex: _sorts.keys.toList().indexOf(_sort));
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging) return;
      setState(() => _sort = _sorts.keys.elementAt(_tabController.index));
      _load();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _tabController.dispose();
    for (final controller in _scrollControllers.values) controller.dispose();
    super.dispose();
  }

  ScrollController _scrollController() => _scrollControllers.putIfAbsent(
        '$_sort|$_category', ScrollController.new);

  Future<void> _load({bool refresh = false}) =>
      context.read<PollProvider>().load(sort: _sort, category: _category, refresh: refresh);

  void _openPost(Post post) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => PollDetailScreen(initialPost: post, pollId: post.pollMeta!.id)));
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<PollProvider>();
    final state = provider.stateFor(sort: _sort, category: _category);
    final controller = _scrollController();
    return Scaffold(
      appBar: AppBar(
        title: const Text('校园投票'),
        actions: [
          IconButton(
            tooltip: '我的投票',
            icon: const Icon(Icons.person_outline),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const MyPollsScreen())),
          ),
        ],
      ),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Align(alignment: Alignment.centerLeft, child: Text('校园投票由用户发起，结果仅代表参与用户的选择。', style: TextStyle(fontSize: 12, color: Colors.black54))),
          ),
          TabBar(controller: _tabController, tabs: _sorts.values.map((label) => Tab(text: label)).toList()),
          SizedBox(
            height: 48,
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              scrollDirection: Axis.horizontal,
              children: _categories.entries.map((entry) => Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(label: Text(entry.value), selected: _category == entry.key, onSelected: (_) { setState(() => _category = entry.key); _load(); }),
                  )).toList(),
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => _load(refresh: true),
              child: state.isLoading && !state.hasLoaded
                  ? const Center(child: CircularProgressIndicator())
                  : state.error != null && state.items.isEmpty
                      ? ListView(children: [SizedBox(height: 240, child: Center(child: Text(state.error!)))])
                      : NotificationListener<ScrollNotification>(
                          onNotification: (notification) {
                            if (notification.metrics.extentAfter < 400 && state.hasMore && !state.isLoadingMore) provider.load(sort: _sort, category: _category);
                            return false;
                          },
                          child: ListView.builder(
                            key: PageStorageKey('poll-center-$_sort-$_category'),
                            controller: controller,
                            padding: const EdgeInsets.fromLTRB(12, 8, 12, 28),
                            itemCount: state.items.length + (state.isLoadingMore ? 1 : 0),
                            itemBuilder: (context, index) {
                              if (index >= state.items.length) return const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator()));
                              final post = state.items[index];
                              return CommunityPostCard(post: post, pollVariant: PollCardVariant.centerFull, onTap: () => _openPost(post), onAuthorTap: (_) {});
                            },
                          ),
                        ),
            ),
          ),
        ],
      ),
    );
  }
}

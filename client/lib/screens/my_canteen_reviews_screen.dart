import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config/api_constants.dart';
import '../models/canteen_review.dart';
import '../providers/auth_provider.dart';
import '../providers/canteen_provider.dart';
import '../utils/app_feedback.dart';
import '../widgets/app_page_app_bar.dart';
import '../widgets/canteen/canteen_status_image.dart';
import '../widgets/canteen/canteen_theme.dart';
import 'canteen_detail_screen.dart';
import 'canteen_review_editor_screen.dart';
import 'canteen_review_history_screen.dart';
import 'canteen_screen.dart';

class MyCanteenReviewsScreen extends StatefulWidget {
  const MyCanteenReviewsScreen({super.key});

  @override
  State<MyCanteenReviewsScreen> createState() => _MyCanteenReviewsScreenState();
}

class _MyCanteenReviewsScreenState extends State<MyCanteenReviewsScreen> {
  final ScrollController _scrollController = ScrollController();
  List<CanteenReviewEvent> _items = const [];
  String? _cursor;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  int? _accountSessionEpoch;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final epoch = context.read<AuthProvider>().accountSessionEpoch;
    if (_accountSessionEpoch == null) {
      _accountSessionEpoch = epoch;
    } else if (_accountSessionEpoch != epoch) {
      _accountSessionEpoch = epoch;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _reload();
      });
    }
  }

  void _onScroll() {
    if (_scrollController.position.extentAfter < 480 && !_loadingMore) {
      _loadMore();
    }
  }

  Future<void> _reload() async {
    final auth = context.read<AuthProvider>();
    if (!auth.isLoggedIn) {
      if (mounted) {
        setState(() {
          _items = const [];
          _cursor = null;
          _loading = false;
          _error = null;
        });
      }
      return;
    }
    final epoch = auth.accountSessionEpoch;
    final page = await context.read<CanteenProvider>().loadMyCanteenReviews();
    if (!mounted || auth.accountSessionEpoch != epoch) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    setState(() {
      _items = page?.items ?? const [];
      _cursor = page?.nextCursor;
      _loading = false;
      _error =
          page == null ? context.read<CanteenProvider>().errorMessage : null;
    });
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || _cursor == null) return;
    final auth = context.read<AuthProvider>();
    if (!auth.isLoggedIn) return;
    final epoch = auth.accountSessionEpoch;
    setState(() => _loadingMore = true);
    final page = await context.read<CanteenProvider>().loadMyCanteenReviews(
          cursor: _cursor,
        );
    if (!mounted || auth.accountSessionEpoch != epoch) {
      if (mounted) setState(() => _loadingMore = false);
      return;
    }
    setState(() {
      if (page != null) {
        _items = [..._items, ...page.items];
        _cursor = page.nextCursor;
      }
      _loadingMore = false;
    });
  }

  Future<void> _openCanteen(CanteenReviewEvent item) async {
    final canteen = item.canteen;
    if (canteen == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CanteenDetailScreen(
          canteenId: canteen.id,
          canteenName: canteen.name,
        ),
      ),
    );
    if (mounted) await _reload();
  }

  Future<void> _openHistory(CanteenReviewEvent item) async {
    final canteen = item.canteen;
    final userId = context.read<AuthProvider>().user?.id;
    if (canteen == null || userId == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CanteenReviewHistoryScreen(
          canteenId: canteen.id,
          canteenName: canteen.name,
          userId: userId,
          isOwn: true,
        ),
      ),
    );
    if (mounted) await _reload();
  }

  Future<void> _edit(CanteenReviewEvent item) async {
    final canteen = item.canteen;
    if (!item.canEdit || canteen == null) return;
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => CanteenReviewEditorScreen(
          canteenId: canteen.id,
          canteenName: canteen.name,
          canteenImage: canteen.image,
          mode: CanteenReviewEditorMode.edit,
          existingReview: {
            'review_event_id': item.id,
            'score_version': item.scoreVersion,
            'taste_score': item.dimensions.taste,
            'value_score': item.dimensions.value,
            'queue_score': item.dimensions.queue,
            'hygiene_score': item.dimensions.hygiene,
            'service_score': item.dimensions.service,
            'overall_score': item.overallScore,
            'comment': item.comment,
            'images': item.images,
            'tags': item.tags,
            'recommended_dishes': item.recommendedDishes,
            'updated_at': item.updatedAt?.toIso8601String(),
          },
        ),
      ),
    );
    if (result == true && mounted) await _reload();
  }

  Future<void> _delete(CanteenReviewEvent item) async {
    final source = item.source == 'legacy' ? 'legacy' : 'v2';
    final id = source == 'legacy' ? item.legacyRatingId : item.id;
    if (id == null || id <= 0) return;
    final key = '$source:$id';
    final confirmed = await AppFeedback.confirmDanger(
      context,
      title: '删除这条评价？',
      message: '删除后将从食堂评价中移除，历史记录不会再参与评分统计。',
      confirmText: '删除',
    );
    if (!confirmed || !mounted) return;
    final result = await context.read<CanteenProvider>().deleteReview(
          id: id,
          source: source,
        );
    if (!mounted) return;
    if (!result.success) {
      AppFeedback.error(result.errorMessage ?? '删除失败，请稍后重试', context: context);
      return;
    }
    setState(() => _items = _items.where((entry) {
          final entrySource = entry.source == 'legacy' ? 'legacy' : 'v2';
          final entryId = entrySource == 'legacy'
              ? entry.legacyRatingId ?? entry.id
              : entry.id;
          return '$entrySource:$entryId' != key;
        }).toList());
    AppFeedback.success('评价已删除', context: context);
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: CanteenTheme.pageBg(isDark),
      appBar: const AppPageAppBar(title: Text('我的食堂评价')),
      body: RefreshIndicator(
        onRefresh: _reload,
        child: _buildBody(isDark),
      ),
    );
  }

  Widget _buildBody(bool isDark) {
    if (_loading) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: List.generate(3, (_) => _buildSkeleton(isDark)),
      );
    }
    if (_error != null) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(
            height: 360,
            child: Center(
              child:
                  FilledButton(onPressed: _reload, child: const Text('重新加载')),
            ),
          ),
        ],
      );
    }
    if (_items.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(
            height: 420,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 36),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.rate_review_outlined,
                        size: 42,
                        color: CanteenTheme.textTertiaryColor(isDark)),
                    const SizedBox(height: 16),
                    Text('还没有食堂评价',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: CanteenTheme.textPrimaryColor(isDark),
                        )),
                    const SizedBox(height: 8),
                    Text(
                      '吃过学校食堂后，\n可以留下真实体验给其他同学参考。',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        height: 1.5,
                        color: CanteenTheme.textSecondaryColor(isDark),
                      ),
                    ),
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const CanteenScreen()),
                      ),
                      child: const Text('去看看食堂'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      );
    }
    return ListView.builder(
      controller: _scrollController,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      itemCount: _items.length + 1 + (_loadingMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              '按评价时间倒序',
              style: TextStyle(
                fontSize: 13,
                color: CanteenTheme.textSecondaryColor(isDark),
              ),
            ),
          );
        }
        final itemIndex = index - 1;
        if (itemIndex >= _items.length) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(
                child: SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))),
          );
        }
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: _buildReviewCard(_items[itemIndex], isDark),
        );
      },
    );
  }

  Widget _buildSkeleton(bool isDark) {
    final color = CanteenTheme.surfaceMutedBg(isDark);
    return Container(
      height: 224,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: CanteenTheme.surfaceBg(isDark),
        borderRadius: BorderRadius.circular(CanteenTheme.radiusLg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(width: 52, height: 52, color: color),
            const SizedBox(width: 12),
            Expanded(child: Container(height: 16, color: color))
          ]),
          const SizedBox(height: 20),
          Container(width: 120, height: 16, color: color),
          const SizedBox(height: 14),
          Container(width: double.infinity, height: 12, color: color),
          const SizedBox(height: 8),
          Container(width: 220, height: 12, color: color),
          const Spacer(),
          Container(width: 140, height: 12, color: color),
        ],
      ),
    );
  }

  Widget _buildReviewCard(CanteenReviewEvent item, bool isDark) {
    final canteen = item.canteen;
    final edited = item.updatedAt != null &&
        item.createdAt != null &&
        item.updatedAt!.difference(item.createdAt!).abs() >
            const Duration(seconds: 1);
    final date = item.createdAt == null ? '' : _date(item.createdAt!);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: CanteenTheme.surfaceBg(isDark),
        borderRadius: BorderRadius.circular(CanteenTheme.radiusLg),
        border: Border.all(color: CanteenTheme.borderColor(isDark)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: canteen == null ? null : () => _openCanteen(item),
            borderRadius: BorderRadius.circular(CanteenTheme.radiusMd),
            child: Row(
              children: [
                if (canteen != null)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(CanteenTheme.radiusMd),
                    child: SizedBox(
                      width: 52,
                      height: 52,
                      child: CanteenStatusImage(
                        imageUrl: ApiConstants.fullUrl(canteen.image),
                        offline: canteen.isOffline,
                        errorWidget: (_, __, ___) => ColoredBox(
                          color: CanteenTheme.surfaceMutedBg(isDark),
                          child: Icon(Icons.storefront_outlined,
                              color: CanteenTheme.textTertiaryColor(isDark)),
                        ),
                      ),
                    ),
                  ),
                if (canteen != null) const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(canteen?.name ?? '未知食堂',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: CanteenTheme.textPrimaryColor(isDark),
                          )),
                      const SizedBox(height: 4),
                      Text(
                        canteen?.isOffline == true ? '已下架' : '当前营业',
                        style: TextStyle(
                          fontSize: 11,
                          color: canteen?.isOffline == true
                              ? CanteenTheme.textTertiaryColor(isDark)
                              : CanteenTheme.textSecondaryColor(isDark),
                        ),
                      ),
                    ],
                  ),
                ),
                if (canteen != null)
                  Icon(Icons.chevron_right,
                      size: 20, color: CanteenTheme.textTertiaryColor(isDark)),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Icon(Icons.star_rounded,
                  size: 17, color: CanteenTheme.accentColor(isDark)),
              const SizedBox(width: 4),
              Text(item.overallScore.toStringAsFixed(1),
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              const Spacer(),
              Text('$date${edited ? ' · 已编辑' : ''}',
                  style: TextStyle(
                    fontSize: 12,
                    color: CanteenTheme.textTertiaryColor(isDark),
                  )),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              _scoreChip('味道', item.dimensions.taste, isDark),
              _scoreChip('性价比', item.dimensions.value, isDark),
              _scoreChip('排队', item.dimensions.queue, isDark),
              _scoreChip('卫生', item.dimensions.hygiene, isDark),
              _scoreChip('服务', item.dimensions.service, isDark),
            ],
          ),
          if (item.comment.trim().isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(item.comment,
                maxLines: 6,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.5,
                  color: CanteenTheme.textPrimaryColor(isDark),
                )),
          ],
          if (item.images.isNotEmpty) ...[
            const SizedBox(height: 10),
            SizedBox(
              height: 68,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: item.images.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (_, index) => ClipRRect(
                  borderRadius: BorderRadius.circular(CanteenTheme.radiusSm),
                  child: CachedNetworkImage(
                    imageUrl: ApiConstants.fullUrl(item.images[index]),
                    width: 68,
                    height: 68,
                    fit: BoxFit.cover,
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Text(
                  item.canEdit ? '最近一次 · 可修改' : '历史评价',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: item.canEdit
                        ? CanteenTheme.accentStrongColor(isDark)
                        : CanteenTheme.textSecondaryColor(isDark),
                  ),
                ),
              ),
              if (item.canEdit && canteen != null)
                TextButton(
                  onPressed: () => _openHistory(item),
                  child: const Text('历史评价'),
                ),
              PopupMenuButton<String>(
                tooltip: '评价操作',
                onSelected: (value) {
                  if (value == 'edit') _edit(item);
                  if (value == 'delete') _delete(item);
                },
                itemBuilder: (_) => [
                  if (item.canEdit)
                    const PopupMenuItem(value: 'edit', child: Text('修改这条评价')),
                  if (item.canDelete)
                    const PopupMenuItem(
                      value: 'delete',
                      child:
                          Text('删除这条评价', style: TextStyle(color: Colors.red)),
                    ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _scoreChip(String label, int score, bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: CanteenTheme.surfaceMutedBg(isDark),
        borderRadius: BorderRadius.circular(CanteenTheme.radiusSm),
      ),
      child: Text('$label $score',
          style: TextStyle(
            fontSize: 11,
            color: CanteenTheme.textSecondaryColor(isDark),
          )),
    );
  }

  String _date(DateTime date) =>
      '${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
}

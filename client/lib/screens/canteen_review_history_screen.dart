import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/canteen_review.dart';
import '../providers/canteen_provider.dart';
import '../theme/app_motion.dart';
import '../utils/app_feedback.dart';
import '../widgets/app_page_app_bar.dart';
import '../widgets/canteen/canteen_theme.dart';
import 'canteen_review_editor_screen.dart';

class CanteenReviewHistoryScreen extends StatefulWidget {
  final int canteenId;
  final String canteenName;
  final int userId;
  final bool isOwn;

  const CanteenReviewHistoryScreen({
    super.key,
    required this.canteenId,
    required this.canteenName,
    required this.userId,
    this.isOwn = false,
  });

  @override
  State<CanteenReviewHistoryScreen> createState() =>
      _CanteenReviewHistoryScreenState();
}

class _CanteenReviewHistoryScreenState
    extends State<CanteenReviewHistoryScreen> {
  List<CanteenReviewEvent> _items = const [];
  bool _loading = true;
  String? _error;
  final Set<String> _deleting = <String>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final provider = context.read<CanteenProvider>();
    final result = await provider.loadReviews(
      widget.canteenId,
      history: true,
      userId: widget.userId,
    );
    if (!mounted) return;
    setState(() {
      _items = result ?? const [];
      _loading = false;
      _error = result == null ? provider.errorMessage : null;
    });
  }

  String _keyFor(CanteenReviewEvent item) {
    final source = item.source == 'legacy' || item.scoreVersion < 2
        ? 'legacy'
        : 'v2';
    final id = source == 'legacy' ? item.legacyRatingId ?? item.id : item.id;
    return '$source:$id';
  }

  Future<void> _delete(CanteenReviewEvent item) async {
    final source = item.source == 'legacy' || item.scoreVersion < 2
        ? 'legacy'
        : 'v2';
    final id = source == 'legacy' ? item.legacyRatingId : item.id;
    if (id == null || id <= 0) {
      AppFeedback.error('这条旧评价暂时无法定位，请刷新后重试', context: context);
      return;
    }
    final key = '$source:$id';
    if (_deleting.contains(key)) return;
    final confirmed = await AppFeedback.confirmDanger(
      context,
      title: '删除这条评价？',
      message: '删除后将从这家食堂的有效评价中移除。',
      confirmText: '删除',
    );
    if (!confirmed || !mounted) return;
    setState(() => _deleting.add(key));
    final result = await context.read<CanteenProvider>().deleteReview(
          id: id,
          source: source,
        );
    if (!mounted) return;
    if (result.success) {
      setState(() {
        _items = _items.where((entry) => _keyFor(entry) != key).toList();
        _deleting.remove(key);
      });
      AppFeedback.success('评价已删除', context: context);
      return;
    }
    setState(() => _deleting.remove(key));
    AppFeedback.error(
      result.errorMessage ?? '删除失败，请稍后重试',
      context: context,
    );
  }

  Future<void> _edit(CanteenReviewEvent item) async {
    if (!item.canEdit || item.scoreVersion < 2) return;
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => CanteenReviewEditorScreen(
          canteenId: widget.canteenId,
          canteenName: widget.canteenName,
          mode: CanteenReviewEditorMode.edit,
          existingReview: _editorPayload(item),
        ),
      ),
    );
    if (result == true && mounted) await _load();
  }

  Map<String, dynamic> _editorPayload(CanteenReviewEvent item) => {
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
        'created_at': item.createdAt?.toIso8601String(),
        'updated_at': item.updatedAt?.toIso8601String(),
      };

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: CanteenTheme.pageBg(isDark),
      appBar: AppPageAppBar(title: Text('我在${widget.canteenName}的评价')),
      body: RefreshIndicator(
        onRefresh: _load,
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
            child: Center(child: Text(_error!)),
          ),
        ],
      );
    }
    if (_items.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(
            height: 360,
            child: Center(child: Text('暂无历史评价')),
          ),
        ],
      );
    }
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        Text(
          '共 ${_items.length} 次到店评价',
          style: TextStyle(
            fontSize: 13,
            color: CanteenTheme.textSecondaryColor(isDark),
          ),
        ),
        const SizedBox(height: 12),
        for (final item in _items) ...[
          _buildCard(item, isDark),
          const SizedBox(height: 12),
        ],
      ],
    );
  }

  Widget _buildSkeleton(bool isDark) {
    final color = CanteenTheme.surfaceMutedBg(isDark);
    return Container(
      height: 178,
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: CanteenTheme.surfaceBg(isDark),
        borderRadius: BorderRadius.circular(CanteenTheme.radiusLg),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(width: 110, height: 16, color: color),
          const SizedBox(height: 16),
          Container(width: double.infinity, height: 12, color: color),
          const SizedBox(height: 8),
          Container(width: 220, height: 12, color: color),
          const Spacer(),
          Container(width: 140, height: 12, color: color),
        ],
      ),
    );
  }

  Widget _buildCard(CanteenReviewEvent item, bool isDark) {
    final key = _keyFor(item);
    final deleting = _deleting.contains(key);
    final edited = item.updatedAt != null &&
        item.createdAt != null &&
        item.updatedAt!.difference(item.createdAt!).abs() > const Duration(seconds: 1);
    return AnimatedSize(
      duration: AppMotion.fast,
      curve: AppMotion.outgoing,
      child: deleting
          ? const SizedBox.shrink()
          : Container(
              key: ValueKey(key),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: CanteenTheme.surfaceBg(isDark),
                borderRadius: BorderRadius.circular(CanteenTheme.radiusLg),
                border: Border.all(color: CanteenTheme.borderColor(isDark)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.star_rounded,
                          size: 17, color: CanteenTheme.accentColor(isDark)),
                      const SizedBox(width: 4),
                      Text(item.overallScore.toStringAsFixed(1),
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                      const Spacer(),
                      Text(
                        '${_date(item.createdAt)}${edited ? ' · 已编辑' : ''}',
                        style: TextStyle(
                          fontSize: 12,
                          color: CanteenTheme.textTertiaryColor(isDark),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
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
                        style: TextStyle(
                          fontSize: 14,
                          height: 1.5,
                          color: CanteenTheme.textPrimaryColor(isDark),
                        )),
                  ],
                  if (item.images.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text('图片 ${item.images.length} 张',
                        style: TextStyle(
                          fontSize: 12,
                          color: CanteenTheme.textSecondaryColor(isDark),
                        )),
                  ],
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          item.canEdit ? '最近一次 · 可修改' : '历史记录',
                          style: TextStyle(
                            fontSize: 12,
                            color: item.canEdit
                                ? CanteenTheme.accentStrongColor(isDark)
                                : CanteenTheme.textSecondaryColor(isDark),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      PopupMenuButton<String>(
                        tooltip: '评价操作',
                        onSelected: (value) {
                          if (value == 'edit') _edit(item);
                          if (value == 'delete') _delete(item);
                        },
                        itemBuilder: (_) => [
                          if (item.canEdit)
                            const PopupMenuItem(
                              value: 'edit',
                              child: Text('修改这条评价'),
                            ),
                          if (item.canDelete)
                            const PopupMenuItem(
                              value: 'delete',
                              child: Text('删除这条评价',
                                  style: TextStyle(color: Colors.red)),
                            ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
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

  String _date(DateTime? date) {
    if (date == null) return '';
    return '${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }
}

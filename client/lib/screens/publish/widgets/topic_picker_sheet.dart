import 'dart:async';

import 'package:flutter/material.dart';

import '../../../models/topic.dart';
import '../../../services/topic_service.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_radius.dart';
import '../../../theme/app_spacing.dart';
import '../../../theme/app_text_styles.dart';

/// 打开完整话题选择器。返回值是 Sheet 关闭时的最终选择结果。
Future<List<TopicSelection>?> showTopicPickerSheet(
  BuildContext context, {
  required TopicService service,
  required String section,
  required List<Topic> recommendedTopics,
  required List<TopicSelection> selectedTopics,
  required int maxTopics,
}) {
  return showModalBottomSheet<List<TopicSelection>>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(AppRadius.sheet),
      ),
    ),
    builder: (_) => _TopicPickerSheet(
      service: service,
      section: section,
      recommendedTopics: recommendedTopics,
      initialTopics: selectedTopics,
      maxTopics: maxTopics,
    ),
  );
}

class _TopicPickerSheet extends StatefulWidget {
  final TopicService service;
  final String section;
  final List<Topic> recommendedTopics;
  final List<TopicSelection> initialTopics;
  final int maxTopics;

  const _TopicPickerSheet({
    required this.service,
    required this.section,
    required this.recommendedTopics,
    required this.initialTopics,
    required this.maxTopics,
  });

  @override
  State<_TopicPickerSheet> createState() => _TopicPickerSheetState();
}

class _TopicPickerSheetState extends State<_TopicPickerSheet> {
  final _controller = TextEditingController();
  Timer? _searchDebounce;
  late List<TopicSelection> _selected;
  List<Topic> _results = const [];
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _selected = [...widget.initialTopics];
    _results = [...widget.recommendedTopics];
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onSearchChanged(String raw) {
    final query = raw.trim();
    _searchDebounce?.cancel();
    if (query.isEmpty) {
      setState(() {
        _results = [...widget.recommendedTopics];
        _loading = false;
        _error = null;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    _searchDebounce = Timer(const Duration(milliseconds: 260), () async {
      try {
        final found = await widget.service.search(
          query: query,
          section: widget.section,
          limit: 20,
        );
        if (!mounted) return;
        setState(() {
          _results = found;
          _loading = false;
        });
      } catch (_) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _error = '搜索失败，请重试';
        });
      }
    });
  }

  void _select(TopicSelection topic) {
    if (_selected.length >= widget.maxTopics ||
        _selected
            .any((item) => item.id == topic.id && item.name == topic.name)) {
      return;
    }
    setState(() => _selected.add(topic));
  }

  void _remove(TopicSelection topic) {
    setState(() => _selected.remove(topic));
  }

  String _cleanName(String raw) =>
      raw.trim().replaceFirst(RegExp(r'^[#＃]+'), '').trim();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final selectedIds = _selected.map((topic) => topic.id).toSet();
    final visibleResults = _results
        .where((topic) => !selectedIds.contains(topic.id))
        .toList(growable: false);
    final customName = _cleanName(_controller.text);
    final hasExact = visibleResults.any((topic) => topic.name == customName) ||
        _selected.any((topic) => topic.name == customName);

    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.lg,
        0,
        AppSpacing.lg,
        AppSpacing.lg + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SizedBox(
        height: 560,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  '添加话题',
                  style: AppTextStyles.titleMedium.copyWith(
                    color: isDark
                        ? AppColors.textPrimaryDark
                        : AppColors.textPrimaryLight,
                  ),
                ),
                const Spacer(),
                Text(
                  '${_selected.length}/${widget.maxTopics}',
                  style: AppTextStyles.labelMedium.copyWith(
                    color: isDark
                        ? AppColors.textTertiaryDark
                        : AppColors.textTertiaryLight,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _controller,
              autofocus: true,
              onChanged: _onSearchChanged,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search_rounded),
                hintText: '搜索或创建话题',
                border: OutlineInputBorder(),
              ),
            ),
            if (_selected.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.md),
              Text('已选择', style: AppTextStyles.labelMedium),
              const SizedBox(height: AppSpacing.xs),
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.xs,
                children: _selected
                    .map(
                      (topic) => InputChip(
                        label: Text('#${topic.name}'),
                        onDeleted: () => _remove(topic),
                        visualDensity: VisualDensity.compact,
                      ),
                    )
                    .toList(growable: false),
              ),
            ],
            if (_loading) const LinearProgressIndicator(minHeight: 2),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.xs),
                child: Text(
                  _error!,
                  style: TextStyle(color: AppColors.danger),
                ),
              ),
            const SizedBox(height: AppSpacing.sm),
            Expanded(
              child: ListView(
                children: [
                  if (customName.isNotEmpty && !hasExact)
                    ListTile(
                      minVerticalPadding: AppSpacing.xs,
                      leading: const Icon(Icons.add_circle_outline),
                      title: Text('#$customName'),
                      subtitle: const Text('发布帖子时创建'),
                      onTap: _selected.length >= widget.maxTopics
                          ? null
                          : () => _select(TopicSelection.custom(customName)),
                    ),
                  if (visibleResults.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(
                        left: AppSpacing.sm,
                        top: AppSpacing.xs,
                        bottom: AppSpacing.xs,
                      ),
                      child: Text(
                        _controller.text.trim().isEmpty ? '为你推荐' : '搜索结果',
                        style: AppTextStyles.labelMedium.copyWith(
                          color: isDark
                              ? AppColors.textSecondaryDark
                              : AppColors.textSecondaryLight,
                        ),
                      ),
                    ),
                  ...visibleResults.map(
                    (topic) => ListTile(
                      minVerticalPadding: AppSpacing.xs,
                      leading: const Icon(Icons.tag_rounded),
                      title: Text('#${topic.name}'),
                      onTap: _selected.length >= widget.maxTopics
                          ? null
                          : () => _select(
                                TopicSelection.existing(
                                  id: topic.id,
                                  name: topic.name,
                                ),
                              ),
                    ),
                  ),
                  if (!_loading && visibleResults.isEmpty && customName.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(AppSpacing.xl),
                      child: Text('暂无结果，输入关键词搜索或创建'),
                    ),
                ],
              ),
            ),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton(
                onPressed: () => Navigator.of(context).pop(_selected),
                child: const Text('完成'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

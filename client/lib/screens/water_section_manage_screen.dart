import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:provider/provider.dart';

import '../models/water_moderator.dart';
import '../models/water_moderation.dart';
import '../models/water_section.dart';
import '../models/water_section_level_title.dart';
import '../providers/water_moderator_provider.dart';
import '../providers/water_moderation_provider.dart';
import '../providers/water_section_provider.dart';
import 'water/water_section_display_edit_screen.dart';

/// 版块管理页�?
/// 按当前用户权限展示任免、禁言列表和操作日志�?
class WaterSectionManageScreen extends StatefulWidget {
  final WaterSection section;

  const WaterSectionManageScreen({super.key, required this.section});

  @override
  State<WaterSectionManageScreen> createState() =>
      _WaterSectionManageScreenState();
}

class _ManageTabItem {
  final String label;
  final Widget child;

  const _ManageTabItem({
    required this.label,
    required this.child,
  });
}

class _WaterSectionManageScreenState extends State<WaterSectionManageScreen> {
  // 等级称号管理状�?
  List<WaterSectionLevelTitle>? _levelTitles;
  final List<TextEditingController> _levelTitleControllers =
      List.generate(8, (_) => TextEditingController());
  bool _savingLevelTitles = false;
  bool _showArchivedTags = false;

  @override
  void dispose() {
    for (final c in _levelTitleControllers) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshAll();
    });
  }

  Future<void> _loadModerators() async {
    try {
      await context
          .read<WaterModeratorProvider>()
          .loadModerators(widget.section.slug);
    } catch (e) {
      // silently ignore �?403 etc means user has no access
    } finally {
      if (mounted) setState(() {});
    }
  }

  Future<void> _loadMutes() async {
    await context
        .read<WaterModerationProvider>()
        .loadMutes(widget.section.slug);
  }

  Future<void> _loadLogs() async {
    await context.read<WaterModerationProvider>().loadLogs(widget.section.slug);
  }

  Future<void> _refreshAll() async {
    final sectionProvider = context.read<WaterSectionProvider>();
    final moderatorProvider = context.read<WaterModeratorProvider>();
    await moderatorProvider.loadMyPermission(
      widget.section.slug,
      forceRefresh: true,
    );
    if (!mounted) return;
    final perm = moderatorProvider.permissionOf(widget.section.slug);
    if (perm.canManageTags || perm.isGlobalAdmin) {
      await sectionProvider.refreshSectionForManage(widget.section.slug);
    } else {
      await sectionProvider.refreshSection(widget.section.slug);
    }
    if (!mounted) return;
    if (perm.canManageModerators) {
      await _loadModerators();
    }
    if (perm.canMuteUser) {
      await _loadMutes();
    }
    if (perm.isGlobalAdmin || perm.isModerator) {
      await _loadLogs();
    }
    if (perm.canEditSection || perm.isGlobalAdmin) {
      await _loadLevelTitles();
    }
  }

  List<WaterSectionModerator> get _moderators =>
      context.watch<WaterModeratorProvider>().moderatorsOf(widget.section.slug);

  Color _sectionAccent() {
    final section = context.watch<WaterSectionProvider>().getBySlug(
              widget.section.slug,
            ) ??
        widget.section;
    if (section.colorHex.isNotEmpty) {
      return colorHexToColor(section.colorHex);
    }
    return const Color(0xFF147C72);
  }

  Color _borderColor(bool isDark) {
    return isDark
        ? Colors.white.withValues(alpha: 0.08)
        : const Color(0xFFE2EFEA);
  }

  BoxDecoration _manageCardDecoration(bool isDark, {Color? borderColor}) {
    return BoxDecoration(
      color: isDark ? const Color(0xFF1E2226) : Colors.white,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(
        color: borderColor ?? _borderColor(isDark),
      ),
      boxShadow: isDark
          ? null
          : [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.025),
                blurRadius: 14,
                offset: const Offset(0, 6),
              ),
            ],
    );
  }

  InputDecoration _manageInputDecoration(
    BuildContext context, {
    String? label,
    String? hint,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = _sectionAccent();
    return InputDecoration(
      labelText: label,
      hintText: hint,
      filled: true,
      fillColor: isDark ? const Color(0xFF1E2226) : Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: _borderColor(isDark)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: _borderColor(isDark)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: accent, width: 1.3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final section = context.watch<WaterSectionProvider>().getBySlug(
              widget.section.slug,
            ) ??
        widget.section;
    final background =
        isDark ? const Color(0xFF111315) : const Color(0xFFFFFAF4);

    return Scaffold(
      backgroundColor: background,
      appBar: AppBar(
        backgroundColor: background,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        title: Text(
          '管理 · ${section.title}',
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
        ),
      ),
      body: _buildContent(isDark, section),
    );
  }

  Widget _buildErrorView(bool isDark) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock_outline_rounded,
                size: 48,
                color: isDark ? Colors.white38 : const Color(0xFF9CA3AF)),
            const SizedBox(height: 16),
            Text(
              '无权访问',
              style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: isDark ? Colors.white : const Color(0xFF20232A)),
            ),
            const SizedBox(height: 8),
            Text(
              '你没有该版块的管理权�?,
              style: TextStyle(
                  fontSize: 13,
                  color: isDark ? Colors.white54 : const Color(0xFF7B818C)),
            ),
            const SizedBox(height: 24),
            OutlinedButton(
              onPressed: _refreshAll,
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(bool isDark, WaterSection section) {
    final perm = context
        .watch<WaterModeratorProvider>()
        .permissionOf(widget.section.slug);
    if (!perm.isGlobalAdmin && !perm.isModerator) {
      return _buildErrorView(isDark);
    }

    final tabs = <_ManageTabItem>[
      if (perm.canEditSection || perm.isGlobalAdmin)
        _ManageTabItem(
          label: '展示',
          child: _buildDisplaySettings(section, isDark),
        ),
      if (perm.canEditSection || perm.isGlobalAdmin)
        _ManageTabItem(
          label: '等级称号',
          child: _buildLevelTitleManagement(section, isDark),
        ),
      if (perm.canManageTags || perm.isGlobalAdmin)
        _ManageTabItem(
          label: '标签',
          child: _buildTagManagement(section, isDark),
        ),
      if (perm.canManageModerators)
        _ManageTabItem(
          label: '版主',
          child: _buildModeratorManagement(isDark),
        ),
      if (perm.canMuteUser)
        _ManageTabItem(
          label: '禁言',
          child: _buildMutesSection(isDark),
        ),
      _ManageTabItem(
        label: '日志',
        child: _buildLogsSection(isDark),
      ),
    ];

    final accent = _sectionAccent();
    final cardColor = isDark ? const Color(0xFF1E2226) : Colors.white;

    return DefaultTabController(
      length: tabs.length,
      child: Column(
        children: [
          // ── 轻量版块头部�?──
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            padding: const EdgeInsets.all(12),
            decoration: _manageCardDecoration(isDark),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.05)
                        : const Color(0xFFF3F4F6),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    iconKeyToIconData(section.iconKey,
                        fallbackSlug: section.slug),
                    color: accent,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        section.title,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                          color:
                              isDark ? Colors.white : const Color(0xFF20232A),
                        ),
                      ),
                      Text(
                        section.subtitle.isNotEmpty
                            ? section.subtitle
                            : section.description,
                        style: TextStyle(
                          fontSize: 12,
                          color:
                              isDark ? Colors.white54 : const Color(0xFF7B818C),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '管理�?,
                    style: TextStyle(
                        fontSize: 11,
                        color: accent,
                        fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
          ),

          // ── 胶囊工具�?──
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: cardColor,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: _borderColor(isDark)),
            ),
            child: TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              indicator: BoxDecoration(
                color: accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(14),
              ),
              indicatorSize: TabBarIndicatorSize.tab,
              dividerColor: Colors.transparent,
              labelColor: accent,
              unselectedLabelColor:
                  isDark ? Colors.white60 : const Color(0xFF6B7280),
              labelStyle:
                  const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
              unselectedLabelStyle:
                  const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
              tabs:
                  tabs.map((tab) => Tab(text: tab.label, height: 34)).toList(),
            ),
          ),

          Expanded(
            child: TabBarView(
              children: tabs
                  .map(
                    (tab) => RefreshIndicator(
                      onRefresh: () async => _refreshAll(),
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
                        children: [tab.child],
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDisplaySettings(WaterSection section, bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildPreviewCard(section, isDark),
        const SizedBox(height: 12),
        _buildContentConfigCard(section, isDark),
        const SizedBox(height: 12),
        _buildPromptQuestionsCard(section, isDark),
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          height: 52,
          child: FilledButton(
            onPressed: () => _showDisplaySettingsSheet(section),
            style: FilledButton.styleFrom(
              backgroundColor: _sectionAccent(),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
              ),
            ),
            child: const Text(
              '编辑展示设置',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPreviewCard(WaterSection section, bool isDark) {
    final accent = _sectionAccent();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: LinearGradient(
          colors: [
            accent.withValues(alpha: isDark ? 0.2 : 0.1),
            accent.withValues(alpha: isDark ? 0.05 : 0.02),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(
          color: accent.withValues(alpha: 0.2),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isDark ? Colors.white12 : Colors.white,
                ),
                child: Icon(
                  iconKeyToIconData(section.iconKey,
                      fallbackSlug: section.slug),
                  color: accent,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      section.title.isNotEmpty ? section.title : '未命名版�?,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: isDark ? Colors.white : const Color(0xFF20232A),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      section.subtitle.isNotEmpty
                          ? section.subtitle
                          : '这里可以写一句简单的副标�?,
                      style: TextStyle(
                        fontSize: 13,
                        color:
                            isDark ? Colors.white70 : const Color(0xFF525A66),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: isDark ? Colors.black26 : Colors.white54,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text('展示预览',
                    style: TextStyle(
                        fontSize: 10,
                        color: accent,
                        fontWeight: FontWeight.w700)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            section.description.isNotEmpty
                ? section.description
                : '版块描述空空如也...',
            style: TextStyle(
              fontSize: 13,
              color: isDark ? Colors.white60 : const Color(0xFF525A66),
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerRight,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: accent,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                section.publishActionText.isNotEmpty
                    ? section.publishActionText
                    : '发布帖子',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContentConfigCard(WaterSection section, bool isDark) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: _manageCardDecoration(isDark),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '内容配置',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w800,
              color: isDark ? Colors.white : const Color(0xFF20232A),
            ),
          ),
          const SizedBox(height: 16),
          _buildConfigItem(
              isDark,
              '发帖按钮',
              section.publishActionText.isNotEmpty
                  ? section.publishActionText
                  : '默认'),
          _buildConfigItem(isDark, '默认排序', _sortLabel(section.defaultSort)),
          _buildConfigItem(
            isDark,
            '空状�?,
            section.emptyTitle.isNotEmpty ? section.emptyTitle : '默认',
            subtitle: section.emptyDescription,
          ),
        ],
      ),
    );
  }

  Widget _buildConfigItem(bool isDark, String label, String value,
      {String? subtitle}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 70,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: isDark ? Colors.white54 : const Color(0xFF7B818C),
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 13,
                    color: isDark ? Colors.white : const Color(0xFF20232A),
                  ),
                ),
                if (subtitle != null && subtitle.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark ? Colors.white38 : const Color(0xFF9CA3AF),
                    ),
                  ),
                ]
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPromptQuestionsCard(WaterSection section, bool isDark) {
    final questions = section.starterQuestions;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: _manageCardDecoration(isDark),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '引导问题',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  color: isDark ? Colors.white : const Color(0xFF20232A),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${questions.length}',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: isDark ? Colors.white38 : const Color(0xFF9CA3AF),
                ),
              ),
            ],
          ),
          if (questions.isNotEmpty) const SizedBox(height: 12),
          if (questions.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '暂未配置引导问题',
                style: TextStyle(
                  fontSize: 13,
                  color: isDark ? Colors.white38 : const Color(0xFF9CA3AF),
                ),
              ),
            ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: questions
                .take(3)
                .map((q) => Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: isDark
                            ? Colors.white.withValues(alpha: 0.05)
                            : const Color(0xFFF3F4F6),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        q,
                        style: TextStyle(
                          fontSize: 12,
                          color:
                              isDark ? Colors.white70 : const Color(0xFF525A66),
                        ),
                      ),
                    ))
                .toList()
              ..addAll([
                if (questions.length > 3)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: isDark
                          ? Colors.white.withValues(alpha: 0.05)
                          : const Color(0xFFF3F4F6),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '+${questions.length - 3}',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color:
                            isDark ? Colors.white70 : const Color(0xFF525A66),
                      ),
                    ),
                  ),
              ]),
          ),
        ],
      ),
    );
  }

  Widget _buildTagManagement(WaterSection section, bool isDark) {
    final tags = [...section.tags]
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    final enabledTags = tags.where((tag) => tag.isEnabled).toList();
    final archivedTags = tags.where((tag) => !tag.isEnabled).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '标签管理',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w800,
                color: isDark ? Colors.white : const Color(0xFF20232A),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${enabledTags.length}启用 · ${archivedTags.length}归档',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: isDark ? Colors.white38 : const Color(0xFF9CA3AF),
              ),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: () => _showTagFormSheet(section),
              icon: const Icon(Icons.add_circle_outline, size: 18),
              label: const Text('新增标签'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (tags.isEmpty)
          _buildEmptyList(isDark, '暂无标签')
        else ...[
          _buildTagGroupHeader('启用�?, enabledTags.length, isDark),
          if (enabledTags.isEmpty)
            _buildEmptyList(isDark, '暂无启用标签')
          else
            ...enabledTags.map((tag) => _buildTagCard(section, tag, isDark)),
          if (archivedTags.isNotEmpty) ...[
            const SizedBox(height: 4),
            _buildArchivedTagHeader(archivedTags.length, isDark),
            if (_showArchivedTags)
              ...archivedTags.map((tag) => _buildTagCard(section, tag, isDark)),
          ],
        ],
      ],
    );
  }

  Widget _buildTagGroupHeader(String label, int count, bool isDark) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: isDark ? Colors.white70 : const Color(0xFF3B4050),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '$count',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: isDark ? Colors.white38 : const Color(0xFF9CA3AF),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildArchivedTagHeader(int count, bool isDark) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          _buildTagGroupHeader('已归�?, count, isDark),
          const Spacer(),
          TextButton.icon(
            onPressed: () {
              setState(() => _showArchivedTags = !_showArchivedTags);
            },
            icon: Icon(
              _showArchivedTags
                  ? Icons.keyboard_arrow_up_rounded
                  : Icons.keyboard_arrow_down_rounded,
              size: 18,
            ),
            label: Text(_showArchivedTags ? '收起' : '查看'),
          ),
        ],
      ),
    );
  }

  Widget _buildTagCard(WaterSection section, WaterSectionTag tag, bool isDark) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: _manageCardDecoration(isDark),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        tag.name,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          color:
                              isDark ? Colors.white : const Color(0xFF20232A),
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: tag.isEnabled
                            ? const Color(0xFF16A34A).withValues(alpha: 0.12)
                            : const Color(0xFF9CA3AF).withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        tag.isEnabled ? '启用' : '已归�?,
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          color: tag.isEnabled
                              ? const Color(0xFF16A34A)
                              : const Color(0xFF6B7280),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '${tag.slug} · 排序 ${tag.sortOrder}${tag.isDefault ? ' · 默认' : ''}',
                  style: TextStyle(
                    fontSize: 11,
                    color: isDark ? Colors.white38 : const Color(0xFF9CA3AF),
                  ),
                ),
                if (tag.description.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    tag.description,
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark ? Colors.white54 : const Color(0xFF7B818C),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          PopupMenuButton<String>(
            icon: Icon(
              Icons.more_horiz,
              size: 20,
              color: isDark ? Colors.white54 : const Color(0xFF9CA3AF),
            ),
            color: isDark ? const Color(0xFF2C3136) : Colors.white,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'edit',
                child: Row(
                  children: [
                    Icon(Icons.edit_outlined, size: 18),
                    SizedBox(width: 8),
                    Text('编辑标签', style: TextStyle(fontSize: 14)),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'toggle',
                child: Row(
                  children: [
                    Icon(
                      tag.isEnabled
                          ? Icons.archive_outlined
                          : Icons.unarchive_outlined,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Text(tag.isEnabled ? '归档标签' : '恢复标签',
                        style: const TextStyle(fontSize: 14)),
                  ],
                ),
              ),
            ],
            onSelected: (value) {
              if (value == 'edit') {
                _showTagFormSheet(section, existing: tag);
              } else if (value == 'toggle') {
                _confirmTagStatus(section, tag);
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _buildModeratorManagement(bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildModeratorListHeader(isDark),
        const SizedBox(height: 8),
        if (_moderators.isEmpty)
          _buildEmptyModerators(isDark)
        else
          ..._moderators.map((m) => _buildModeratorCard(m, isDark)),
      ],
    );
  }

  String _sortLabel(String value) {
    switch (value) {
      case 'all':
      case 'recommend':
        return '默认排序';
      case 'time':
      case 'latest':
        return '最新发�?;
      case 'featured':
        return '精华内容';
      case 'following':
        return '关注的人';
      default:
        return value;
    }
  }

  Future<void> _showDisplaySettingsSheet(WaterSection section) async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => WaterSectionDisplayEditScreen(section: section),
      ),
    );
    if (changed == true && mounted) {
      _refreshAll();
    }
  }

  void _showTagFormSheet(WaterSection section, {WaterSectionTag? existing}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: isDark ? const Color(0xFF171B24) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => _TagFormSheet(
        sectionSlug: section.slug,
        existing: existing,
      ),
    );
  }

  void _confirmTagStatus(WaterSection section, WaterSectionTag tag) {
    final willEnable = !tag.isEnabled;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(willEnable ? '恢复标签' : '归档标签'),
        content: Text(
          willEnable
              ? '恢复后，学生发帖时可以重新选择�?{tag.name}」，版块页也会重新显示该标签入口�?
              : '归档后，学生发帖时不能再选择�?{tag.name}」，版块页也不再显示该标签入口。已有帖子不会删除，仍会出现在综合、最新、精华、推荐中�?,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              final provider = context.read<WaterSectionProvider>();
              final ok = willEnable
                  ? await provider.enableTag(
                      sectionSlug: section.slug,
                      tagId: tag.id,
                      reason: '恢复标签',
                      includeDisabledTags: true,
                    )
                  : await provider.disableTag(
                      sectionSlug: section.slug,
                      tagId: tag.id,
                      reason: '归档标签',
                      includeDisabledTags: true,
                    );
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    ok
                        ? (willEnable ? '标签已恢�? : '标签已归�?)
                        : provider.error ?? '操作失败',
                  ),
                ),
              );
              if (ok) _loadLogs();
            },
            child: Text(willEnable ? '确认恢复' : '确认归档'),
          ),
        ],
      ),
    );
  }

  // ── 版主列表 ──

  Widget _buildModeratorListHeader(bool isDark) {
    return Row(
      children: [
        Text(
          '版主列表',
          style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: isDark ? Colors.white : const Color(0xFF20232A)),
        ),
        const SizedBox(width: 8),
        Text(
          '${_moderators.length}',
          style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: isDark ? Colors.white38 : const Color(0xFF9CA3AF)),
        ),
        const Spacer(),
        TextButton.icon(
          onPressed: () => _showAddModeratorSheet(),
          icon: const Icon(Icons.person_add_outlined, size: 18),
          label: const Text('添加版主'),
        ),
      ],
    );
  }

  Widget _buildEmptyModerators(bool isDark) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 40),
      decoration: _manageCardDecoration(isDark),
      child: Column(
        children: [
          Icon(Icons.group_outlined,
              size: 36,
              color: isDark ? Colors.white24 : const Color(0xFFD1D5DB)),
          const SizedBox(height: 12),
          Text(
            '暂无版主',
            style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: isDark ? Colors.white54 : const Color(0xFF7B818C)),
          ),
          const SizedBox(height: 4),
          Text(
            '点击上方“添加版主”任命该版块的管理�?,
            style: TextStyle(
                fontSize: 12,
                color: isDark ? Colors.white38 : const Color(0xFF9CA3AF)),
          ),
        ],
      ),
    );
  }

  Widget _buildModeratorCard(WaterSectionModerator mod, bool isDark) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: _manageCardDecoration(isDark),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 18,
            backgroundImage: mod.user?.avatarUrl.isNotEmpty == true
                ? NetworkImage(mod.user!.avatarUrl)
                : null,
            child: mod.user?.avatarUrl.isEmpty == true
                ? Text(
                    mod.displayName.isNotEmpty
                        ? mod.displayName[0].toUpperCase()
                        : '?',
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 14),
                  )
                : null,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      mod.displayName,
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color:
                              isDark ? Colors.white : const Color(0xFF20232A)),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: mod.role == 'owner'
                            ? const Color(0xFFF59E0B).withValues(alpha: 0.15)
                            : const Color(0xFF3B82F6).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        mod.roleLabel,
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: mod.role == 'owner'
                              ? const Color(0xFFD97706)
                              : const Color(0xFF2563EB),
                        ),
                      ),
                    ),
                  ],
                ),
                Text(
                  'ID: ${mod.userId}',
                  style: TextStyle(
                      fontSize: 11,
                      color: isDark ? Colors.white38 : const Color(0xFF9CA3AF)),
                ),
                if (mod.enabledPermissions.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: mod.enabledPermissions
                        .map((p) => Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: isDark
                                    ? Colors.white.withValues(alpha: 0.06)
                                    : const Color(0xFFF3F4F6),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                p,
                                style: TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w600,
                                  color: isDark
                                      ? Colors.white60
                                      : const Color(0xFF667085),
                                ),
                              ),
                            ))
                        .toList(),
                  ),
                ],
              ],
            ),
          ),
          PopupMenuButton<String>(
            icon: Icon(
              Icons.more_horiz,
              size: 20,
              color: isDark ? Colors.white54 : const Color(0xFF9CA3AF),
            ),
            color: isDark ? const Color(0xFF2C3136) : Colors.white,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'edit',
                child: Row(
                  children: [
                    Icon(Icons.edit_outlined, size: 18),
                    SizedBox(width: 8),
                    Text('修改权限', style: TextStyle(fontSize: 14)),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'revoke',
                child: Row(
                  children: [
                    Icon(Icons.remove_circle_outline,
                        size: 18, color: Colors.red),
                    SizedBox(width: 8),
                    Text('罢免版主',
                        style: TextStyle(fontSize: 14, color: Colors.red)),
                  ],
                ),
              ),
            ],
            onSelected: (value) {
              if (value == 'edit') {
                _showEditModeratorSheet(mod);
              } else if (value == 'revoke') {
                _confirmRevoke(mod);
              }
            },
          ),
        ],
      ),
    );
  }

  // ── 添加 / 编辑弹窗 ──

  void _showAddModeratorSheet({WaterSectionModerator? existing}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: isDark ? const Color(0xFF171B24) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => _ModeratorFormSheet(
        sectionSlug: widget.section.slug,
        existing: existing,
      ),
    );
  }

  void _showEditModeratorSheet(WaterSectionModerator existing) {
    _showAddModeratorSheet(existing: existing);
  }

  void _confirmRevoke(WaterSectionModerator mod) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('罢免版主'),
        content: Text('确认要罢免�?{mod.displayName}」在'
            '�?{widget.section.title}」版块的版主权限吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              try {
                await context.read<WaterModeratorProvider>().revokeModerator(
                      sectionSlug: widget.section.slug,
                      moderatorId: mod.id,
                    );
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('已罢免版�?)),
                  );
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('操作失败: $e')),
                  );
                }
              }
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('确认罢免'),
          ),
        ],
      ),
    );
  }

  // ── 禁言列表 ──

  Widget _buildMutesSection(bool isDark) {
    final mutes =
        context.watch<WaterModerationProvider>().mutesOf(widget.section.slug);
    final isLoading = context.watch<WaterModerationProvider>().isLoadingMutes;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '禁言列表',
              style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  color: isDark ? Colors.white : const Color(0xFF20232A)),
            ),
            const SizedBox(width: 8),
            Text(
              '${mutes.length}',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: isDark ? Colors.white38 : const Color(0xFF9CA3AF)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (isLoading)
          Container(
            padding: const EdgeInsets.all(20),
            decoration: _manageCardDecoration(isDark),
            child:
                const Center(child: CircularProgressIndicator(strokeWidth: 2)),
          )
        else if (mutes.isEmpty)
          _buildEmptyList(isDark, '暂无正在禁言的用�?)
        else
          ...mutes.map((m) => _buildMuteCard(m, isDark)),
      ],
    );
  }

  Widget _buildMuteCard(WaterSectionMute mute, bool isDark) {
    final untilText = mute.until != null
        ? '�?${mute.until!.toLocal().toString().substring(0, 16)}'
        : '永久';
    final isExpired =
        mute.until != null && mute.until!.isBefore(DateTime.now());
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: _manageCardDecoration(isDark),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 14,
                child: Text(
                  mute.displayName.isNotEmpty
                      ? mute.displayName[0].toUpperCase()
                      : '?',
                  style: const TextStyle(fontSize: 11),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(mute.displayName,
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color:
                            isDark ? Colors.white : const Color(0xFF20232A))),
              ),
              if (isExpired)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.orange.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: const Text('已过�?,
                      style: TextStyle(fontSize: 10, color: Colors.orange)),
                )
              else
                TextButton.icon(
                  onPressed: () => _confirmUnmute(mute),
                  icon: const Icon(Icons.lock_open_outlined, size: 14),
                  label: const Text('解除', style: TextStyle(fontSize: 11)),
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(0, 24),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(mute.reason,
              style: TextStyle(
                  fontSize: 12,
                  color: isDark ? Colors.white54 : const Color(0xFF7B818C))),
          const SizedBox(height: 4),
          Text(untilText,
              style: TextStyle(
                  fontSize: 11,
                  color: isDark ? Colors.white38 : const Color(0xFF9CA3AF))),
        ],
      ),
    );
  }

  void _confirmUnmute(WaterSectionMute mute) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('解除禁言'),
        content: Text('确认解除�?{mute.displayName}」在本版块的禁言吗？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              final ok =
                  await context.read<WaterModerationProvider>().unmuteUser(
                        sectionSlug: widget.section.slug,
                        userId: mute.userId,
                      );
              if (!mounted) return;
              if (ok) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('已解除禁言')),
                );
                _loadMutes();
                _loadLogs();
              } else {
                final error = context.read<WaterModerationProvider>().error;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(error ?? '解除禁言失败')),
                );
              }
            },
            child: const Text('确认'),
          ),
        ],
      ),
    );
  }

  // ── 操作日志 ──

  Widget _buildLogsSection(bool isDark) {
    final logs = context
        .watch<WaterModerationProvider>()
        .logsOf(widget.section.slug)
        .logs;
    final isLoading = context.watch<WaterModerationProvider>().isLoadingLogs;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '操作日志',
              style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  color: isDark ? Colors.white : const Color(0xFF20232A)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (isLoading)
          Container(
            padding: const EdgeInsets.all(20),
            decoration: _manageCardDecoration(isDark),
            child:
                const Center(child: CircularProgressIndicator(strokeWidth: 2)),
          )
        else if (logs.isEmpty)
          _buildEmptyList(isDark, '暂无管理记录')
        else
          ...logs.map((l) => _buildLogCard(l, isDark)),
      ],
    );
  }

  Widget _buildLogCard(WaterModerationLog log, bool isDark) {
    final time =
        log.createdAt != null ? _formatFriendlyTime(log.createdAt!) : '';
    final perm = context
        .watch<WaterModeratorProvider>()
        .permissionOf(widget.section.slug);
    final canRestorePost = perm.isGlobalAdmin &&
        log.action == 'delete_post' &&
        log.targetType == 'post' &&
        log.targetId > 0;

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Timeline line
          SizedBox(
            width: 24,
            child: Stack(
              alignment: Alignment.topCenter,
              children: [
                Positioned(
                  top: 8,
                  bottom: -16, // draw line beyond bottom
                  child: Container(
                    width: 2,
                    color: isDark ? Colors.white10 : const Color(0xFFEDEFF3),
                  ),
                ),
                Positioned(
                  top: 8,
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _sectionAccent(),
                      border: Border.all(
                          color: isDark
                              ? const Color(0xFF111315)
                              : const Color(0xFFFFFAF4),
                          width: 2),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Container(
              margin: const EdgeInsets.only(bottom: 16),
              padding: const EdgeInsets.all(12),
              decoration: _manageCardDecoration(isDark),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(log.actionLabel,
                            style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: isDark
                                    ? Colors.white
                                    : const Color(0xFF20232A))),
                        const SizedBox(height: 4),
                        Text(log.reason.isNotEmpty ? log.reason : '无原�?,
                            style: TextStyle(
                                fontSize: 12,
                                color: isDark
                                    ? Colors.white54
                                    : const Color(0xFF7B818C)),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis),
                        const SizedBox(height: 6),
                        Text(time,
                            style: TextStyle(
                                fontSize: 11,
                                color: isDark
                                    ? Colors.white38
                                    : const Color(0xFF9CA3AF))),
                      ],
                    ),
                  ),
                  if (canRestorePost)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        TextButton.icon(
                          onPressed: context
                                  .watch<WaterModerationProvider>()
                                  .isOperating
                              ? null
                              : () => _confirmRestorePost(log),
                          icon: const Icon(Icons.restore_rounded, size: 14),
                          label:
                              const Text('恢复', style: TextStyle(fontSize: 11)),
                          style: TextButton.styleFrom(
                            minimumSize: const Size(0, 28),
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmRestorePost(WaterModerationLog log) async {
    final reasonController = TextEditingController(text: '恢复误删帖子');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('恢复帖子'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('确认恢复帖子 #${log.targetId} 吗？'),
            const SizedBox(height: 12),
            TextField(
              controller: reasonController,
              maxLength: 100,
              decoration: const InputDecoration(
                labelText: '恢复原因',
                hintText: '可�?,
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认恢复'),
          ),
        ],
      ),
    );
    final reason = reasonController.text.trim();
    reasonController.dispose();
    if (!mounted || confirmed != true) return;

    final provider = context.read<WaterModerationProvider>();
    final ok = await provider.restorePost(
      sectionSlug: widget.section.slug,
      postId: log.targetId,
      reason: reason,
    );
    if (!mounted) return;
    if (ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('帖子已恢�?)),
      );
      _loadLogs();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(provider.error ?? '恢复帖子失败')),
      );
    }
  }

  // ── 等级称号管理 ──────────────────────────────────────────────────────────

  Future<void> _loadLevelTitles() async {
    final svc = context.read<WaterSectionProvider>().service;
    if (svc == null) return;
    try {
      final titles = await svc.fetchLevelTitles(widget.section.slug);
      if (!mounted) return;
      setState(() {
        _levelTitles = titles;
        for (int i = 0; i < titles.length && i < 8; i++) {
          _levelTitleControllers[i].text =
              titles[i].custom ? titles[i].title : '';
        }
      });
    } catch (e) {
      debugPrint('加载等级称号失败: $e');
    }
  }

  Future<void> _saveLevelTitles() async {
    final svc = context.read<WaterSectionProvider>().service;
    if (svc == null) return;
    setState(() => _savingLevelTitles = true);
    try {
      final input = List.generate(8, (i) {
        final title = _levelTitleControllers[i].text.trim();
        if (title.isEmpty) {
          return {'level': i + 1, 'reset': true};
        }
        return {'level': i + 1, 'title': title};
      });
      await svc.updateLevelTitles(
        sectionSlug: widget.section.slug,
        titles: input,
      );
      if (!mounted) return;
      await _loadLevelTitles();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('等级称号已保�?)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败: $e')),
      );
    } finally {
      if (mounted) setState(() => _savingLevelTitles = false);
    }
  }

  Widget _buildLevelTitleManagement(WaterSection section, bool isDark) {
    if (_levelTitles == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(40),
          child: CircularProgressIndicator(),
        ),
      );
    }

    final accent = _sectionAccent();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: _manageCardDecoration(isDark),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '自定义称�?,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  color: isDark ? Colors.white : const Color(0xFF20232A),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '自定义版�?Lv.1 �?Lv.8 的称号，留空则沿用默认称�?,
                style: TextStyle(
                  fontSize: 12,
                  color: isDark ? Colors.white54 : const Color(0xFF7B818C),
                ),
              ),
              const SizedBox(height: 20),
              ...List.generate(8, (i) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: isDark
                              ? Colors.white.withValues(alpha: 0.05)
                              : const Color(0xFFF3F4F6),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          'Lv.${i + 1}',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                            color: isDark
                                ? Colors.white70
                                : const Color(0xFF374151),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: SizedBox(
                          height: 44,
                          child: TextField(
                            controller: _levelTitleControllers[i],
                            style: TextStyle(
                              fontSize: 13,
                              color: isDark
                                  ? Colors.white
                                  : const Color(0xFF20232A),
                            ),
                            decoration: _manageInputDecoration(
                              context,
                              hint: _levelTitles != null &&
                                      i < _levelTitles!.length
                                  ? _levelTitles![i].title
                                  : '',
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              }),
            ],
          ),
        ),
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          height: 52,
          child: FilledButton(
            onPressed: _savingLevelTitles ? null : _saveLevelTitles,
            style: FilledButton.styleFrom(
              backgroundColor: accent,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
              ),
            ),
            child: _savingLevelTitles
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        color: Colors.white, strokeWidth: 2),
                  )
                : const Text('保存等级称号',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyList(bool isDark, String text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 24),
      decoration: _manageCardDecoration(isDark),
      child: Center(
        child: Text(text,
            style: TextStyle(
                fontSize: 12,
                color: isDark ? Colors.white38 : const Color(0xFF9CA3AF))),
      ),
    );
  }

  String _formatFriendlyTime(DateTime time) {
    final local = time.toLocal();
    final now = DateTime.now();
    final diff = now.difference(local);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes}分钟�?;
    if (diff.inDays < 1) return '${diff.inHours}小时�?;
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '$month/$day $hour:$minute';
  }
}

class _TagFormSheet extends StatefulWidget {
  final String sectionSlug;
  final WaterSectionTag? existing;

  const _TagFormSheet({
    required this.sectionSlug,
    this.existing,
  });

  @override
  State<_TagFormSheet> createState() => _TagFormSheetState();
}

class _TagFormSheetState extends State<_TagFormSheet> {
  late final TextEditingController _slugController;
  late final TextEditingController _nameController;
  late final TextEditingController _descriptionController;
  late final TextEditingController _sortOrderController;
  late final TextEditingController _reasonController;
  bool _isDefault = false;
  bool _isSubmitting = false;

  bool get _isEditing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final tag = widget.existing;
    _slugController = TextEditingController(text: tag?.slug ?? '');
    _nameController = TextEditingController(text: tag?.name ?? '');
    _descriptionController =
        TextEditingController(text: tag?.description ?? '');
    _sortOrderController =
        TextEditingController(text: (tag?.sortOrder ?? 0).toString());
    _reasonController =
        TextEditingController(text: _isEditing ? '修改标签' : '新增标签');
    _isDefault = tag?.isDefault ?? false;
  }

  @override
  void dispose() {
    _slugController.dispose();
    _nameController.dispose();
    _descriptionController.dispose();
    _sortOrderController.dispose();
    _reasonController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final slug = _slugController.text.trim();
    final name = _nameController.text.trim();
    final sortOrder = int.tryParse(_sortOrderController.text.trim()) ?? 0;
    if (!_isEditing && !RegExp(r'^[a-z0-9_-]{1,64}$').hasMatch(slug)) {
      _showSnack('标签标识只允许小写英文、数字、下划线、短横线');
      return;
    }
    if (name.isEmpty) {
      _showSnack('标签名称不能为空');
      return;
    }
    if (name.runes.length > 40) {
      _showSnack('标签名称最�?40 �?);
      return;
    }
    if (_descriptionController.text.trim().runes.length > 200) {
      _showSnack('标签描述最�?200 �?);
      return;
    }

    setState(() => _isSubmitting = true);
    final provider = context.read<WaterSectionProvider>();
    final reason = _reasonController.text.trim();
    final ok = _isEditing
        ? await provider.updateTag(
            sectionSlug: widget.sectionSlug,
            tagId: widget.existing!.id,
            includeDisabledTags: true,
            fields: {
              'name': name,
              'description': _descriptionController.text.trim(),
              'sort_order': sortOrder,
              'is_default': _isDefault,
              if (reason.isNotEmpty) 'reason': reason,
            },
          )
        : await provider.createTag(
            sectionSlug: widget.sectionSlug,
            includeDisabledTags: true,
            fields: {
              'slug': slug,
              'name': name,
              'description': _descriptionController.text.trim(),
              'sort_order': sortOrder,
              'is_default': _isDefault,
              if (reason.isNotEmpty) 'reason': reason,
            },
          );
    if (!mounted) return;
    setState(() => _isSubmitting = false);
    if (ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_isEditing ? '标签已保�? : '标签已新�?)),
      );
      Navigator.pop(context);
    } else {
      _showSnack(provider.error ?? '操作失败');
    }
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        20,
        20,
        20 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSheetHandle(isDark),
            const SizedBox(height: 16),
            _buildSheetTitle(_isEditing ? '编辑标签' : '新增标签', isDark),
            const SizedBox(height: 16),
            _buildTextField(_slugController, '标签标识', isDark,
                enabled: !_isEditing),
            _buildTextField(_nameController, '标签名称', isDark),
            _buildTextField(_descriptionController, '标签描述', isDark,
                maxLines: 3),
            _buildTextField(_sortOrderController, '排序�?, isDark,
                keyboardType: TextInputType.number),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                '默认标签',
                style: TextStyle(
                  fontSize: 13.5,
                  color: isDark ? Colors.white : const Color(0xFF20232A),
                ),
              ),
              value: _isDefault,
              onChanged: (value) => setState(() => _isDefault = value),
            ),
            _buildTextField(_reasonController, '操作原因', isDark),
            const SizedBox(height: 18),
            _buildSubmitButton(
              label: _isEditing ? '保存标签' : '新增标签',
              isSubmitting: _isSubmitting,
              onPressed: _submit,
            ),
          ],
        ),
      ),
    );
  }
}

Widget _buildSheetHandle(bool isDark) {
  return Center(
    child: Container(
      width: 36,
      height: 4,
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.18)
            : const Color(0xFFE5E7EB),
        borderRadius: BorderRadius.circular(999),
      ),
    ),
  );
}

Widget _buildSheetTitle(String title, bool isDark) {
  return Text(
    title,
    style: TextStyle(
      fontSize: 18,
      fontWeight: FontWeight.w800,
      color: isDark ? Colors.white : const Color(0xFF20232A),
    ),
  );
}

InputDecoration _inputDecoration(String label, bool isDark) {
  return InputDecoration(
    labelText: label,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
    ),
    filled: true,
    fillColor:
        isDark ? Colors.white.withValues(alpha: 0.06) : const Color(0xFFF9FAFB),
  );
}

Widget _buildTextField(
  TextEditingController controller,
  String label,
  bool isDark, {
  int maxLines = 1,
  bool enabled = true,
  TextInputType? keyboardType,
}) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(
      controller: controller,
      maxLines: maxLines,
      enabled: enabled,
      keyboardType: keyboardType,
      decoration: _inputDecoration(label, isDark),
    ),
  );
}

Widget _buildSubmitButton({
  required String label,
  required bool isSubmitting,
  required VoidCallback onPressed,
}) {
  return SizedBox(
    width: double.infinity,
    height: 48,
    child: FilledButton(
      onPressed: isSubmitting ? null : onPressed,
      style: FilledButton.styleFrom(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
      ),
      child: isSubmitting
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            )
          : Text(
              label,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
    ),
  );
}

class _ModeratorFormSheet extends StatefulWidget {
  final String sectionSlug;
  final WaterSectionModerator? existing;

  const _ModeratorFormSheet({
    required this.sectionSlug,
    this.existing,
  });

  @override
  State<_ModeratorFormSheet> createState() => _ModeratorFormSheetState();
}

class _ModeratorFormSheetState extends State<_ModeratorFormSheet> {
  final _userIdController = TextEditingController();
  final _reasonController = TextEditingController();
  String _role = 'moderator';
  bool _canEditSection = false;
  bool _canManageTags = false;
  bool _canPinPost = true;
  bool _canDeletePost = true;
  bool _canMuteUser = true;
  bool _isSubmitting = false;

  bool get _isEditing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final mod = widget.existing;
    if (mod != null) {
      _userIdController.text = mod.userId.toString();
      _role = mod.role;
      _canEditSection = mod.canEditSection;
      _canManageTags = mod.canManageTags;
      _canPinPost = mod.canPinPost;
      _canDeletePost = mod.canDeletePost;
      _canMuteUser = mod.canMuteUser;
      _reasonController.text = mod.assignReason;
    }
  }

  @override
  void dispose() {
    _userIdController.dispose();
    _reasonController.dispose();
    super.dispose();
  }

  void _onRoleChanged(String role) {
    setState(() {
      _role = role;
      if (role == 'owner') {
        _canEditSection = true;
        _canManageTags = true;
        _canPinPost = true;
        _canDeletePost = true;
        _canMuteUser = true;
      } else {
        _canEditSection = false;
        _canManageTags = false;
        _canPinPost = true;
        _canDeletePost = true;
        _canMuteUser = true;
      }
    });
  }

  Future<void> _submit() async {
    if (!_isEditing) {
      final userIdText = _userIdController.text.trim();
      if (userIdText.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请输入用�?ID')),
        );
        return;
      }
      final userId = int.tryParse(userIdText);
      if (userId == null || userId <= 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请输入有效的用户 ID')),
        );
        return;
      }
      if (mounted) setState(() => _isSubmitting = true);
      try {
        await context.read<WaterModeratorProvider>().createModerator(
              sectionSlug: widget.sectionSlug,
              userId: userId,
              role: _role,
              canEditSection: _canEditSection,
              canManageTags: _canManageTags,
              canPinPost: _canPinPost,
              canDeletePost: _canDeletePost,
              canMuteUser: _canMuteUser,
              reason: _reasonController.text.trim(),
            );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已任命版�?)),
          );
          Navigator.pop(context);
        }
      } on DioException catch (e) {
        final msg = _mapDioError(e);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(msg)),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('操作失败: $e')),
          );
        }
      } finally {
        if (mounted) setState(() => _isSubmitting = false);
      }
    } else {
      if (mounted) setState(() => _isSubmitting = true);
      try {
        await context.read<WaterModeratorProvider>().updateModerator(
              sectionSlug: widget.sectionSlug,
              moderatorId: widget.existing!.id,
              role: _role,
              canEditSection: _canEditSection,
              canManageTags: _canManageTags,
              canPinPost: _canPinPost,
              canDeletePost: _canDeletePost,
              canMuteUser: _canMuteUser,
              reason: _reasonController.text.trim().isNotEmpty
                  ? _reasonController.text.trim()
                  : null,
            );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('权限已更�?)),
          );
          Navigator.pop(context);
        }
      } on DioException catch (e) {
        final msg = _mapDioError(e);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(msg)),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('操作失败: $e')),
          );
        }
      } finally {
        if (mounted) setState(() => _isSubmitting = false);
      }
    }
  }

  String _mapDioError(DioException e) {
    final statusCode = e.response?.statusCode;
    if (statusCode == 400) return '用户不存在或不能任命管理员为版主';
    if (statusCode == 409) return '该用户已经是该版块版�?;
    if (statusCode == 403) return '没有权限执行此操�?;
    return '操作失败，请稍后重试';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        20,
        20,
        20 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.18)
                      : const Color(0xFFE5E7EB),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              _isEditing ? '修改版主权限' : '添加版主',
              style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: isDark ? Colors.white : const Color(0xFF20232A)),
            ),
            const SizedBox(height: 18),
            if (!_isEditing) ...[
              TextField(
                controller: _userIdController,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: '用户 ID',
                  hintText: '输入要任命的用户 ID',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  filled: true,
                  fillColor: isDark
                      ? Colors.white.withValues(alpha: 0.06)
                      : const Color(0xFFF9FAFB),
                ),
              ),
              const SizedBox(height: 14),
            ],
            // 角色
            Text(
              '角色',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white70 : const Color(0xFF374151)),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                _buildRoleChip('moderator', '版主', isDark),
                const SizedBox(width: 10),
                _buildRoleChip('owner', '负责�?, isDark),
              ],
            ),
            const SizedBox(height: 14),
            // 权限
            Text(
              '权限',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white70 : const Color(0xFF374151)),
            ),
            const SizedBox(height: 8),
            _buildPermSwitch('编辑版块展示', _canEditSection,
                (v) => setState(() => _canEditSection = v), isDark),
            _buildPermSwitch('管理标签', _canManageTags,
                (v) => setState(() => _canManageTags = v), isDark),
            _buildPermSwitch('置顶帖子', _canPinPost,
                (v) => setState(() => _canPinPost = v), isDark),
            _buildPermSwitch('删除帖子', _canDeletePost,
                (v) => setState(() => _canDeletePost = v), isDark),
            _buildPermSwitch('禁言用户', _canMuteUser,
                (v) => setState(() => _canMuteUser = v), isDark),
            const SizedBox(height: 14),
            TextField(
              controller: _reasonController,
              maxLines: 2,
              decoration: InputDecoration(
                labelText: '任命原因（可选）',
                hintText: '例如：负责课程学习版块维�?,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                filled: true,
                fillColor: isDark
                    ? Colors.white.withValues(alpha: 0.06)
                    : const Color(0xFFF9FAFB),
              ),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton(
                onPressed: _isSubmitting ? null : _submit,
                style: FilledButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: _isSubmitting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : Text(
                        _isEditing ? '保存修改' : '确认任命',
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w700),
                      ),
              ),
            ),
            SizedBox(
                height: MediaQuery.of(context).viewInsets.bottom > 0 ? 16 : 0),
          ],
        ),
      ),
    );
  }

  Widget _buildRoleChip(String value, String label, bool isDark) {
    final selected = _role == value;
    return GestureDetector(
      onTap: () => _onRoleChanged(value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.12)
              : (isDark
                  ? Colors.white.withValues(alpha: 0.06)
                  : const Color(0xFFF3F4F6)),
          borderRadius: BorderRadius.circular(12),
          border: selected
              ? Border.all(
                  color: Theme.of(context)
                      .colorScheme
                      .primary
                      .withValues(alpha: 0.3))
              : null,
        ),
        child: Text(
          label,
          style: TextStyle(
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            fontSize: 13,
            color: selected
                ? Theme.of(context).colorScheme.primary
                : (isDark ? Colors.white60 : const Color(0xFF667085)),
          ),
        ),
      ),
    );
  }

  Widget _buildPermSwitch(
      String label, bool value, ValueChanged<bool> onChanged, bool isDark) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: SwitchListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        title: Text(
          label,
          style: TextStyle(
              fontSize: 13.5,
              color: isDark ? Colors.white : const Color(0xFF20232A)),
        ),
        value: value,
        onChanged: onChanged,
        activeThumbColor: Theme.of(context).colorScheme.primary,
      ),
    );
  }
}

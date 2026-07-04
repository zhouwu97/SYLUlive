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

/// 版块管理页。
/// 按当前用户权限展示任免、禁言列表和操作日志。
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
  // 等级称号管理状态
  List<WaterSectionLevelTitle>? _levelTitles;
  final List<TextEditingController> _levelTitleControllers =
      List.generate(8, (_) => TextEditingController());
  bool _savingLevelTitles = false;

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
      // silently ignore — 403 etc means user has no access
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
    await sectionProvider.refreshSection(widget.section.slug);
    if (!mounted) return;
    await moderatorProvider.loadMyPermission(
      widget.section.slug,
      forceRefresh: true,
    );
    if (!mounted) return;
    final perm = moderatorProvider.permissionOf(widget.section.slug);
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

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final section = context.watch<WaterSectionProvider>().getBySlug(
              widget.section.slug,
            ) ??
        widget.section;
    final background =
        isDark ? const Color(0xFF0D1117) : const Color(0xFFF7F8FA);

    return Scaffold(
      backgroundColor: background,
      appBar: AppBar(
        backgroundColor: isDark ? const Color(0xFF0D1117) : Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
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
              '你没有该版块的管理权限',
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

    return DefaultTabController(
      length: tabs.length,
      child: Column(
        children: [
          Material(
            color: isDark ? const Color(0xFF0D1117) : Colors.white,
            child: TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              tabs: tabs.map((tab) => Tab(text: tab.label)).toList(),
            ),
          ),
          Expanded(
            child: TabBarView(
              children: tabs
                  .map(
                    (tab) => RefreshIndicator(
                      onRefresh: () async => _refreshAll(),
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
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

  // ── 版块信息卡 ──

  Widget _buildSectionInfoCard(WaterSection section, bool isDark) {
    final color = section.colorHex.isNotEmpty
        ? colorHexToColor(section.colorHex)
        : Theme.of(context).colorScheme.primary;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF171B24) : Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.08)
              : const Color(0xFFEDEFF3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                iconKeyToIconData(section.iconKey, fallbackSlug: section.slug),
                size: 22,
                color: color,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  section.title,
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: isDark ? Colors.white : const Color(0xFF20232A)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            section.subtitle.isNotEmpty
                ? section.subtitle
                : section.description,
            style: TextStyle(
                fontSize: 12.5,
                color: isDark ? Colors.white54 : const Color(0xFF7B818C)),
          ),
        ],
      ),
    );
  }

  Widget _buildDisplaySettings(WaterSection section, bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionInfoCard(section, isDark),
        const SizedBox(height: 12),
        _buildInfoRow(isDark, '说明', section.description),
        _buildInfoRow(isDark, '发帖按钮', section.publishActionText),
        _buildInfoRow(isDark, '空状态标题', section.emptyTitle),
        _buildInfoRow(isDark, '空状态描述', section.emptyDescription),
        _buildInfoRow(isDark, '发布提醒', section.noticeText),
        _buildInfoRow(isDark, '默认排序', _sortLabel(section.defaultSort)),
        if (section.starterQuestions.isNotEmpty)
          _buildInfoRow(isDark, '引导问题', section.starterQuestions.join(' / ')),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          height: 46,
          child: FilledButton.icon(
            onPressed: () => _showDisplaySettingsSheet(section),
            icon: const Icon(Icons.tune_outlined, size: 18),
            label: const Text('编辑展示设置'),
          ),
        ),
      ],
    );
  }

  Widget _buildInfoRow(bool isDark, String label, String value) {
    if (value.trim().isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: _cardDecoration(isDark),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: isDark ? Colors.white38 : const Color(0xFF9CA3AF),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              fontSize: 13,
              color: isDark ? Colors.white70 : const Color(0xFF374151),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTagManagement(WaterSection section, bool isDark) {
    final tags = [...section.tags]
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
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
              '${tags.length}',
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
        else
          ...tags.map((tag) => _buildTagCard(section, tag, isDark)),
      ],
    );
  }

  Widget _buildTagCard(WaterSection section, WaterSectionTag tag, bool isDark) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: _cardDecoration(isDark),
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
                    color: isDark ? Colors.white : const Color(0xFF20232A),
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: tag.isEnabled
                      ? const Color(0xFF16A34A).withValues(alpha: 0.12)
                      : const Color(0xFF9CA3AF).withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  tag.isEnabled ? '启用' : '停用',
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
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              OutlinedButton.icon(
                onPressed: () => _showTagFormSheet(section, existing: tag),
                icon: const Icon(Icons.edit_outlined, size: 16),
                label: const Text('编辑', style: TextStyle(fontSize: 12)),
              ),
              const SizedBox(width: 8),
              TextButton.icon(
                onPressed: () => _confirmTagStatus(section, tag),
                icon: Icon(
                  tag.isEnabled
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                  size: 16,
                ),
                label: Text(
                  tag.isEnabled ? '停用' : '启用',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
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
        return '最新发布';
      case 'featured':
        return '精华内容';
      case 'following':
        return '关注的人';
      default:
        return value;
    }
  }

  void _showDisplaySettingsSheet(WaterSection section) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: isDark ? const Color(0xFF171B24) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => _SectionDisplayFormSheet(section: section),
    );
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
        title: Text(willEnable ? '启用标签' : '停用标签'),
        content: Text(
          willEnable
              ? '确认重新启用「${tag.name}」标签吗？'
              : '停用后旧帖仍保留该标签，但新发帖不能再选择它。确认停用「${tag.name}」吗？',
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
                      reason: '启用标签',
                    )
                  : await provider.disableTag(
                      sectionSlug: section.slug,
                      tagId: tag.id,
                      reason: '停用标签',
                    );
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    ok
                        ? (willEnable ? '标签已启用' : '标签已停用')
                        : provider.error ?? '操作失败',
                  ),
                ),
              );
              if (ok) _loadLogs();
            },
            child: Text(willEnable ? '确认启用' : '确认停用'),
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
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF171B24) : Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.08)
              : const Color(0xFFEDEFF3),
        ),
      ),
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
            '点击上方“添加版主”任命该版块的管理者',
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
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF171B24) : Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.08)
              : const Color(0xFFEDEFF3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
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
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      mod.displayName,
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color:
                              isDark ? Colors.white : const Color(0xFF20232A)),
                    ),
                    Text(
                      'ID: ${mod.userId}',
                      style: TextStyle(
                          fontSize: 11,
                          color: isDark
                              ? Colors.white38
                              : const Color(0xFF9CA3AF)),
                    ),
                  ],
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: mod.role == 'owner'
                      ? const Color(0xFFF59E0B).withValues(alpha: 0.15)
                      : const Color(0xFF3B82F6).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  mod.roleLabel,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: mod.role == 'owner'
                        ? const Color(0xFFD97706)
                        : const Color(0xFF2563EB),
                  ),
                ),
              ),
            ],
          ),
          if (mod.enabledPermissions.isNotEmpty) ...[
            const SizedBox(height: 10),
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
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              OutlinedButton.icon(
                onPressed: () => _showEditModeratorSheet(mod),
                icon: const Icon(Icons.edit_outlined, size: 16),
                label: const Text('修改权限', style: TextStyle(fontSize: 12)),
                style: OutlinedButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                ),
              ),
              const SizedBox(width: 8),
              TextButton.icon(
                onPressed: () => _confirmRevoke(mod),
                icon: const Icon(Icons.remove_circle_outline, size: 16),
                label: const Text('罢免', style: TextStyle(fontSize: 12)),
                style: TextButton.styleFrom(
                  foregroundColor: Colors.red,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                ),
              ),
            ],
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
        content: Text('确认要罢免「${mod.displayName}」在'
            '「${widget.section.title}」版块的版主权限吗？'),
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
                    const SnackBar(content: Text('已罢免版主')),
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
            decoration: _cardDecoration(isDark),
            child:
                const Center(child: CircularProgressIndicator(strokeWidth: 2)),
          )
        else if (mutes.isEmpty)
          _buildEmptyList(isDark, '暂无正在禁言的用户')
        else
          ...mutes.map((m) => _buildMuteCard(m, isDark)),
      ],
    );
  }

  Widget _buildMuteCard(WaterSectionMute mute, bool isDark) {
    final untilText = mute.until != null
        ? '至 ${mute.until!.toLocal().toString().substring(0, 16)}'
        : '永久';
    final isExpired =
        mute.until != null && mute.until!.isBefore(DateTime.now());
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: _cardDecoration(isDark),
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
                  child: const Text('已过期',
                      style: TextStyle(fontSize: 10, color: Colors.orange)),
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
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () => _confirmUnmute(mute),
              icon: const Icon(Icons.lock_open_outlined, size: 14),
              label: const Text('解除禁言', style: TextStyle(fontSize: 11)),
            ),
          ),
        ],
      ),
    );
  }

  void _confirmUnmute(WaterSectionMute mute) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('解除禁言'),
        content: Text('确认解除「${mute.displayName}」在本版块的禁言吗？'),
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
            decoration: _cardDecoration(isDark),
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
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(10),
      decoration: _cardDecoration(isDark),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(log.actionLabel,
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color:
                            isDark ? Colors.white : const Color(0xFF20232A))),
                const SizedBox(height: 2),
                Text(log.reason.isNotEmpty ? log.reason : '无原因',
                    style: TextStyle(
                        fontSize: 11,
                        color:
                            isDark ? Colors.white54 : const Color(0xFF7B818C)),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(time,
                  style: TextStyle(
                      fontSize: 10,
                      color:
                          isDark ? Colors.white38 : const Color(0xFF9CA3AF))),
              if (canRestorePost) ...[
                const SizedBox(height: 4),
                TextButton.icon(
                  onPressed:
                      context.watch<WaterModerationProvider>().isOperating
                          ? null
                          : () => _confirmRestorePost(log),
                  icon: const Icon(Icons.restore_rounded, size: 14),
                  label: const Text('恢复', style: TextStyle(fontSize: 11)),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 28),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                ),
              ],
            ],
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
                hintText: '可选',
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
        const SnackBar(content: Text('帖子已恢复')),
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
        const SnackBar(content: Text('等级称号已保存')),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        Text(
          '自定义版块 Lv.1 – Lv.8 的称号，留空则沿用默认称号',
          style: TextStyle(
            fontSize: 13,
            color: isDark ? Colors.white70 : Colors.black54,
          ),
        ),
        const SizedBox(height: 16),
        ...List.generate(8, (i) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(
                  width: 40,
                  child: Text(
                    'Lv.${i + 1}',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                      color: isDark ? Colors.white : const Color(0xFF20232A),
                    ),
                  ),
                ),
                Expanded(
                  child: TextField(
                    controller: _levelTitleControllers[i],
                    style: TextStyle(
                      fontSize: 14,
                      color: isDark ? Colors.white : const Color(0xFF20232A),
                    ),
                    decoration: InputDecoration(
                      hintText: _levelTitles != null && i < _levelTitles!.length
                          ? _levelTitles![i].title
                          : '',
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 10,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(
                          color: isDark ? Colors.white24 : Colors.black12,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        }),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          height: 44,
          child: ElevatedButton(
            onPressed: _savingLevelTitles ? null : _saveLevelTitles,
            child: _savingLevelTitles
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('保存'),
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyList(bool isDark, String text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 24),
      decoration: _cardDecoration(isDark),
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
    if (diff.inHours < 1) return '${diff.inMinutes}分钟前';
    if (diff.inDays < 1) return '${diff.inHours}小时前';
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '$month/$day $hour:$minute';
  }

  BoxDecoration _cardDecoration(bool isDark) {
    return BoxDecoration(
      color: isDark ? const Color(0xFF171B24) : Colors.white,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(
        color: isDark
            ? Colors.white.withValues(alpha: 0.08)
            : const Color(0xFFEDEFF3),
      ),
    );
  }
}

// ── 版主表单 BottomSheet ──

class _SectionDisplayFormSheet extends StatefulWidget {
  final WaterSection section;

  const _SectionDisplayFormSheet({required this.section});

  @override
  State<_SectionDisplayFormSheet> createState() =>
      _SectionDisplayFormSheetState();
}

class _SectionDisplayFormSheetState extends State<_SectionDisplayFormSheet> {
  late final TextEditingController _titleController;
  late final TextEditingController _subtitleController;
  late final TextEditingController _descriptionController;
  late final TextEditingController _iconKeyController;
  late final TextEditingController _colorHexController;
  late final TextEditingController _publishActionController;
  late final TextEditingController _emptyTitleController;
  late final TextEditingController _emptyDescriptionController;
  late final TextEditingController _noticeTextController;
  late final TextEditingController _starterQuestionsController;
  late final TextEditingController _reasonController;
  late String _defaultSort;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    final section = widget.section;
    _titleController = TextEditingController(text: section.title);
    _subtitleController = TextEditingController(text: section.subtitle);
    _descriptionController = TextEditingController(text: section.description);
    _iconKeyController = TextEditingController(text: section.iconKey);
    _colorHexController = TextEditingController(text: section.colorHex);
    _publishActionController =
        TextEditingController(text: section.publishActionText);
    _emptyTitleController = TextEditingController(text: section.emptyTitle);
    _emptyDescriptionController =
        TextEditingController(text: section.emptyDescription);
    _noticeTextController = TextEditingController(text: section.noticeText);
    _starterQuestionsController =
        TextEditingController(text: section.starterQuestions.join('\n'));
    _reasonController = TextEditingController(text: '编辑版块展示');
    _defaultSort = _normalizeSort(section.defaultSort);
  }

  @override
  void dispose() {
    _titleController.dispose();
    _subtitleController.dispose();
    _descriptionController.dispose();
    _iconKeyController.dispose();
    _colorHexController.dispose();
    _publishActionController.dispose();
    _emptyTitleController.dispose();
    _emptyDescriptionController.dispose();
    _noticeTextController.dispose();
    _starterQuestionsController.dispose();
    _reasonController.dispose();
    super.dispose();
  }

  String _normalizeSort(String sort) {
    switch (sort) {
      case 'recommend':
        return 'all';
      case 'latest':
        return 'time';
      case 'all':
      case 'time':
      case 'featured':
      case 'following':
        return sort;
      default:
        return 'all';
    }
  }

  Future<void> _submit() async {
    final title = _titleController.text.trim();
    final colorHex = _colorHexController.text.trim();
    final questions = _starterQuestionsController.text
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (title.isEmpty) {
      _showSnack('标题不能为空');
      return;
    }
    if (colorHex.isNotEmpty &&
        !RegExp(r'^#[0-9A-Fa-f]{6}$').hasMatch(colorHex)) {
      _showSnack('颜色必须为空或符合 #RRGGBB');
      return;
    }
    if (questions.length > 10) {
      _showSnack('引导问题最多 10 条');
      return;
    }
    setState(() => _isSubmitting = true);
    final provider = context.read<WaterSectionProvider>();
    final ok = await provider.updateSectionDisplay(
      slug: widget.section.slug,
      fields: {
        'title': title,
        'subtitle': _subtitleController.text.trim(),
        'description': _descriptionController.text.trim(),
        'icon_key': _iconKeyController.text.trim(),
        'color_hex': colorHex,
        'publish_action_text': _publishActionController.text.trim(),
        'empty_title': _emptyTitleController.text.trim(),
        'empty_description': _emptyDescriptionController.text.trim(),
        'notice_text': _noticeTextController.text.trim(),
        'starter_questions': questions,
        'default_sort': _defaultSort,
        'reason': _reasonController.text.trim().isEmpty
            ? '编辑版块展示'
            : _reasonController.text.trim(),
      },
    );
    if (!mounted) return;
    setState(() => _isSubmitting = false);
    if (ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已保存版块展示设置')),
      );
      Navigator.pop(context);
    } else {
      _showSnack(provider.error ?? '保存失败');
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
            _buildSheetTitle('展示设置', isDark),
            const SizedBox(height: 16),
            _buildTextField(_titleController, '标题', isDark),
            _buildTextField(_subtitleController, '副标题', isDark),
            _buildTextField(_descriptionController, '说明', isDark, maxLines: 3),
            Row(
              children: [
                Expanded(
                    child:
                        _buildTextField(_iconKeyController, '图标 Key', isDark)),
                const SizedBox(width: 10),
                Expanded(
                    child: _buildTextField(
                        _colorHexController, '颜色 #RRGGBB', isDark)),
              ],
            ),
            _buildTextField(_publishActionController, '发帖按钮文案', isDark),
            _buildTextField(_emptyTitleController, '空状态标题', isDark),
            _buildTextField(_emptyDescriptionController, '空状态描述', isDark,
                maxLines: 2),
            _buildTextField(_noticeTextController, '发布提醒', isDark, maxLines: 3),
            _buildTextField(_starterQuestionsController, '引导问题（每行一条）', isDark,
                maxLines: 5),
            DropdownButtonFormField<String>(
              initialValue: _defaultSort,
              decoration: _inputDecoration('默认排序', isDark),
              items: const [
                DropdownMenuItem(value: 'all', child: Text('默认排序')),
                DropdownMenuItem(value: 'time', child: Text('最新发布')),
                DropdownMenuItem(value: 'featured', child: Text('精华内容')),
                DropdownMenuItem(value: 'following', child: Text('关注的人')),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _defaultSort = value);
              },
            ),
            const SizedBox(height: 12),
            _buildTextField(_reasonController, '保存原因', isDark),
            const SizedBox(height: 18),
            _buildSubmitButton(
              label: '保存展示设置',
              isSubmitting: _isSubmitting,
              onPressed: _submit,
            ),
          ],
        ),
      ),
    );
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
      _showSnack('标签名称最多 40 字');
      return;
    }
    if (_descriptionController.text.trim().runes.length > 200) {
      _showSnack('标签描述最多 200 字');
      return;
    }

    setState(() => _isSubmitting = true);
    final provider = context.read<WaterSectionProvider>();
    final reason = _reasonController.text.trim();
    final ok = _isEditing
        ? await provider.updateTag(
            sectionSlug: widget.sectionSlug,
            tagId: widget.existing!.id,
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
        SnackBar(content: Text(_isEditing ? '标签已保存' : '标签已新增')),
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
            _buildTextField(_sortOrderController, '排序值', isDark,
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
          const SnackBar(content: Text('请输入用户 ID')),
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
            const SnackBar(content: Text('已任命版主')),
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
            const SnackBar(content: Text('权限已更新')),
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
    if (statusCode == 409) return '该用户已经是该版块版主';
    if (statusCode == 403) return '没有权限执行此操作';
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
                _buildRoleChip('owner', '负责人', isDark),
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
                hintText: '例如：负责课程学习版块维护',
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

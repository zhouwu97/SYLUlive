import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:provider/provider.dart';

import '../models/water_moderator.dart';
import '../models/water_moderation.dart';
import '../models/water_section.dart';
import '../providers/water_moderator_provider.dart';
import '../providers/water_moderation_provider.dart';

/// 版块管理页 —— 当前只做“版主管理”。
/// 仅 admin / super_admin 可见入口；版主和普通用户无入口。
class WaterSectionManageScreen extends StatefulWidget {
  final WaterSection section;

  const WaterSectionManageScreen({super.key, required this.section});

  @override
  State<WaterSectionManageScreen> createState() =>
      _WaterSectionManageScreenState();
}

class _WaterSectionManageScreenState extends State<WaterSectionManageScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadModerators();
      _loadMutes();
      _loadLogs();
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
    await context.read<WaterModerationProvider>().loadMutes(widget.section.slug);
  }

  Future<void> _loadLogs() async {
    await context.read<WaterModerationProvider>().loadLogs(widget.section.slug);
  }

  void _refreshAll() {
    _loadModerators();
    _loadMutes();
    _loadLogs();
  }

  List<WaterSectionModerator> get _moderators =>
      context.watch<WaterModeratorProvider>().moderatorsOf(widget.section.slug);

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final background =
        isDark ? const Color(0xFF0D1117) : const Color(0xFFF7F8FA);

    return Scaffold(
      backgroundColor: background,
      appBar: AppBar(
        backgroundColor: isDark ? const Color(0xFF0D1117) : Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        title: Text(
          '管理 · ${widget.section.title}',
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
        ),
      ),
      body: _buildContent(isDark),
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
              '只有管理员可以管理版块版主',
              style: TextStyle(
                  fontSize: 13,
                  color: isDark ? Colors.white54 : const Color(0xFF7B818C)),
            ),
            const SizedBox(height: 24),
            OutlinedButton(
              onPressed: _loadModerators,
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(bool isDark) {
    return RefreshIndicator(
      onRefresh: () async => _refreshAll(),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
        children: [
          _buildSectionInfoCard(isDark),
          const SizedBox(height: 16),
          _buildModeratorListHeader(isDark),
          const SizedBox(height: 8),
          if (_moderators.isEmpty)
            _buildEmptyModerators(isDark)
          else
            ..._moderators.map((m) => _buildModeratorCard(m, isDark)),
          const SizedBox(height: 24),
          _buildMutesSection(isDark),
          const SizedBox(height: 24),
          _buildLogsSection(isDark),
        ],
      ),
    );
  }

  // ── 版块信息卡 ──

  Widget _buildSectionInfoCard(bool isDark) {
    final color = widget.section.colorHex.isNotEmpty
        ? colorHexToColor(widget.section.colorHex)
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
                iconKeyToIconData(widget.section.iconKey,
                    fallbackSlug: widget.section.slug),
                size: 22,
                color: color,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.section.title,
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
            widget.section.subtitle.isNotEmpty
                ? widget.section.subtitle
                : widget.section.description,
            style: TextStyle(
                fontSize: 12.5,
                color: isDark ? Colors.white54 : const Color(0xFF7B818C)),
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
                          color:
                              isDark ? Colors.white38 : const Color(0xFF9CA3AF)),
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
                await context
                    .read<WaterModeratorProvider>()
                    .revokeModerator(
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
    final isLoading =
        context.watch<WaterModerationProvider>().isLoadingMutes;

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
            child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
          )
        else if (mutes.isEmpty)
          _buildEmptyList(isDark, '暂无禁言记录')
        else
          ...mutes.map((m) => _buildMuteCard(m, isDark)),
      ],
    );
  }

  Widget _buildMuteCard(WaterSectionMute mute, bool isDark) {
    final untilText = mute.until != null
        ? '至 ${mute.until!.toLocal().toString().substring(0, 16)}'
        : '永久';
    final isExpired = mute.until != null && mute.until!.isBefore(DateTime.now());
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
              CircleAvatar(radius: 14, child: Text(mute.displayName[0].toUpperCase(), style: const TextStyle(fontSize: 11))),
              const SizedBox(width: 8),
              Expanded(
                child: Text(mute.displayName,
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: isDark ? Colors.white : const Color(0xFF20232A))),
              ),
              if (isExpired)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.orange.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: const Text('已过期', style: TextStyle(fontSize: 10, color: Colors.orange)),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(mute.reason,
              style: TextStyle(fontSize: 12, color: isDark ? Colors.white54 : const Color(0xFF7B818C))),
          const SizedBox(height: 4),
          Text(untilText,
              style: TextStyle(fontSize: 11, color: isDark ? Colors.white38 : const Color(0xFF9CA3AF))),
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
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await context.read<WaterModerationProvider>().unmuteUser(
                    sectionSlug: widget.section.slug,
                    userId: mute.userId,
                  );
              if (mounted) _loadMutes();
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
    final isLoading =
        context.watch<WaterModerationProvider>().isLoadingLogs;

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
          _buildEmptyList(isDark, '暂无操作日志')
        else
          ...logs.map((l) => _buildLogCard(l, isDark)),
      ],
    );
  }

  Widget _buildLogCard(WaterModerationLog log, bool isDark) {
    final time = log.createdAt != null
        ? log.createdAt!.toLocal().toString().substring(0, 19)
        : '';
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
                        color: isDark ? Colors.white : const Color(0xFF20232A))),
                const SizedBox(height: 2),
                Text(log.reason.isNotEmpty ? log.reason : '无原因',
                    style: TextStyle(
                        fontSize: 11,
                        color: isDark ? Colors.white54 : const Color(0xFF7B818C)),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          Text(time,
              style: TextStyle(
                  fontSize: 10,
                  color: isDark ? Colors.white38 : const Color(0xFF9CA3AF))),
        ],
      ),
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

// ── 版主表单 BottomSheet ──

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
                  fillColor:
                      isDark ? Colors.white.withValues(alpha: 0.06) : const Color(0xFFF9FAFB),
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
                fillColor:
                    isDark ? Colors.white.withValues(alpha: 0.06) : const Color(0xFFF9FAFB),
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
            SizedBox(height: MediaQuery.of(context).viewInsets.bottom > 0 ? 16 : 0),
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
              fontSize: 13.5, color: isDark ? Colors.white : const Color(0xFF20232A)),
        ),
        value: value,
        onChanged: onChanged,
        activeColor: Theme.of(context).colorScheme.primary,
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../config/api_constants.dart';
import '../providers/auth_provider.dart';
import '../theme/app_colors.dart';
import '../theme/app_radius.dart';
import '../theme/app_spacing.dart';
import '../theme/app_text_styles.dart';
import '../widgets/app_page_app_bar.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';

class AdminAnnouncementsScreen extends StatefulWidget {
  const AdminAnnouncementsScreen({super.key});

  @override
  State<AdminAnnouncementsScreen> createState() =>
      _AdminAnnouncementsScreenState();
}

class _AdminAnnouncementsScreenState extends State<AdminAnnouncementsScreen> {
  // Use FutureBuilder in build like original so we don't strictly need state list
  // But we need a key or setState to refresh the FutureBuilder
  Key _futureKey = UniqueKey();

  void _refresh() {
    setState(() {
      _futureKey = UniqueKey();
    });
  }

  String _announcementDraftKey([int? id]) =>
      'announcement_draft_${id ?? 'new'}';

  Future<void> _showAnnouncementEditor(
    BuildContext context, {
    Map<dynamic, dynamic>? announcement,
  }) async {
    final titleCtrl = TextEditingController();
    final contentCtrl = TextEditingController();
    final isEditing = announcement != null;
    bool isPinned = announcement?['is_pinned'] == true;

    String status = announcement?['status']?.toString() ?? 'published';
    String displayMode = announcement?['display_mode']?.toString() ?? 'center';
    String priority = announcement?['priority']?.toString() ?? 'normal';
    DateTime? publishAt;
    DateTime? expiresAt;
    bool includeNewUsers = announcement?['include_new_users'] == true;

    final rawPublishAt = announcement?['publish_at']?.toString();
    if (rawPublishAt != null && rawPublishAt.isNotEmpty) {
      publishAt = DateTime.tryParse(rawPublishAt);
    }
    final rawExpiresAt = announcement?['expires_at']?.toString();
    if (rawExpiresAt != null && rawExpiresAt.isNotEmpty) {
      expiresAt = DateTime.tryParse(rawExpiresAt);
    }

    final draftKey = _announcementDraftKey(announcement?['id'] as int?);
    final prefs = await AppPreferencesStore.getInstance();
    final draftTitle = prefs.getString('${draftKey}_title');
    final draftContent = prefs.getString('${draftKey}_content');
    final draftPinned = prefs.getBool('${draftKey}_pinned');
    final draftStatus = prefs.getString('${draftKey}_status');
    final draftDisplayMode = prefs.getString('${draftKey}_display_mode');
    final draftPriority = prefs.getString('${draftKey}_priority');
    final draftIncludeNewUsers = prefs.getBool('${draftKey}_include_new');

    titleCtrl.text = draftTitle ?? (announcement?['title']?.toString() ?? '');
    contentCtrl.text =
        draftContent ?? (announcement?['content']?.toString() ?? '');
    isPinned = draftPinned ?? isPinned;
    if (draftStatus != null) status = draftStatus;
    if (draftDisplayMode != null) displayMode = draftDisplayMode;
    if (draftPriority != null) priority = draftPriority;
    if (draftIncludeNewUsers != null) includeNewUsers = draftIncludeNewUsers;

    Future<void> saveDraft() async {
      await prefs.setString('${draftKey}_title', titleCtrl.text);
      await prefs.setString('${draftKey}_content', contentCtrl.text);
      await prefs.setBool('${draftKey}_pinned', isPinned);
      await prefs.setString('${draftKey}_status', status);
      await prefs.setString('${draftKey}_display_mode', displayMode);
      await prefs.setString('${draftKey}_priority', priority);
      await prefs.setBool('${draftKey}_include_new', includeNewUsers);
    }

    void draftListener() {
      saveDraft();
    }

    titleCtrl.addListener(draftListener);
    contentCtrl.addListener(draftListener);

    if (!context.mounted) return;

    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final dialogHeight = (MediaQuery.sizeOf(ctx).height * 0.84)
              .clamp(420.0, 760.0)
              .toDouble();
          final isDark = Theme.of(ctx).brightness == Brightness.dark;

          return Dialog(
            insetPadding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg,
              vertical: AppSpacing.xxl,
            ),
            backgroundColor: isDark
                ? AppColors.surfaceSecondaryDark
                : AppColors.surfaceSecondaryLight,
            surfaceTintColor: Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.sheet),
            ),
            child: Theme(
              data: Theme.of(ctx).copyWith(
                colorScheme: Theme.of(ctx).colorScheme.copyWith(
                      primary: AppColors.brandPrimary,
                      secondary: AppColors.brandPrimary,
                    ),
              ),
              child: SizedBox(
                width: double.infinity,
                height: dialogHeight,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.xl,
                    AppSpacing.lg,
                    AppSpacing.xl,
                    AppSpacing.sm,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  isEditing ? '编辑公告' : '发布公告',
                                  style: AppTextStyles.titleLarge.copyWith(
                                    color: isDark
                                        ? Colors.white
                                        : AppColors.textPrimaryLight,
                                  ),
                                ),
                                const SizedBox(height: AppSpacing.xs),
                                Text(
                                  '完善信息后，公告会按展示方式触达用户',
                                  style: AppTextStyles.bodyMedium.copyWith(
                                    color: isDark
                                        ? Colors.white.withValues(alpha: 0.58)
                                        : AppColors.textSecondaryLight,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: '关闭编辑器',
                            onPressed: () => Navigator.pop(ctx, false),
                            icon: const Icon(Icons.close_rounded),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.md),
                      Expanded(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.only(
                            right: AppSpacing.xs,
                            bottom: AppSpacing.md,
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              TextField(
                                controller: titleCtrl,
                                decoration: const InputDecoration(
                                  labelText: '公告标题',
                                  hintText: '例如：校园社区使用规范更新',
                                  helperText: '显示在首页公告卡片的标题位置。',
                                  border: OutlineInputBorder(),
                                ),
                              ),
                              const SizedBox(height: 12),
                              TextField(
                                controller: contentCtrl,
                                maxLines: 6,
                                decoration: const InputDecoration(
                                  labelText: '公告正文',
                                  hintText: '填写通知详情、执行时间和注意事项',
                                  helperText: '支持完整说明公告事项，发布后所有用户可见。',
                                  helperMaxLines: 2,
                                  border: OutlineInputBorder(),
                                ),
                              ),
                              const SizedBox(height: 12),
                              SwitchListTile(
                                value: isPinned,
                                contentPadding: EdgeInsets.zero,
                                title: const Text('置顶公告'),
                                subtitle: const Text('首页优先展示置顶公告'),
                                onChanged: (value) async {
                                  setDialogState(() => isPinned = value);
                                  await saveDraft();
                                },
                              ),
                              const SizedBox(height: 8),
                              DropdownButtonFormField<String>(
                                initialValue: status,
                                decoration: const InputDecoration(
                                  labelText: '发布状态',
                                  border: OutlineInputBorder(),
                                  contentPadding: EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 14),
                                ),
                                items: const [
                                  DropdownMenuItem(
                                      value: 'draft', child: Text('草稿')),
                                  DropdownMenuItem(
                                      value: 'published', child: Text('已发布')),
                                  DropdownMenuItem(
                                      value: 'archived', child: Text('已归档')),
                                ],
                                onChanged: (v) {
                                  if (v != null) {
                                    setDialogState(() => status = v);
                                    saveDraft();
                                  }
                                },
                              ),
                              const SizedBox(height: 12),
                              DropdownButtonFormField<String>(
                                initialValue: displayMode,
                                decoration: const InputDecoration(
                                  labelText: '展示方式',
                                  border: OutlineInputBorder(),
                                  contentPadding: EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 14),
                                ),
                                items: const [
                                  DropdownMenuItem(
                                      value: 'center', child: Text('公告中心')),
                                  DropdownMenuItem(
                                      value: 'banner', child: Text('首页横幅')),
                                  DropdownMenuItem(
                                      value: 'modal', child: Text('弹窗提醒')),
                                ],
                                onChanged: (v) {
                                  if (v != null) {
                                    setDialogState(() => displayMode = v);
                                    saveDraft();
                                  }
                                },
                              ),
                              const SizedBox(height: 12),
                              DropdownButtonFormField<String>(
                                initialValue: priority,
                                decoration: const InputDecoration(
                                  labelText: '优先级',
                                  border: OutlineInputBorder(),
                                  contentPadding: EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 14),
                                ),
                                items: const [
                                  DropdownMenuItem(
                                      value: 'normal', child: Text('普通')),
                                  DropdownMenuItem(
                                      value: 'important', child: Text('重要')),
                                  DropdownMenuItem(
                                      value: 'urgent', child: Text('紧急')),
                                ],
                                onChanged: (v) {
                                  if (v != null) {
                                    setDialogState(() => priority = v);
                                    saveDraft();
                                  }
                                },
                              ),
                              const SizedBox(height: 12),
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                title: const Text('定时发布'),
                                subtitle: Text(publishAt != null
                                    ? '${publishAt!.toLocal()}'.substring(0, 16)
                                    : '立即发布'),
                                trailing: publishAt != null
                                    ? IconButton(
                                        icon: const Icon(Icons.clear),
                                        onPressed: () => setDialogState(
                                            () => publishAt = null),
                                      )
                                    : null,
                                onTap: () async {
                                  final date = await showDatePicker(
                                    context: ctx,
                                    initialDate: publishAt ?? DateTime.now(),
                                    firstDate: DateTime.now(),
                                    lastDate: DateTime.now()
                                        .add(const Duration(days: 365)),
                                  );
                                  if (date == null || !ctx.mounted) return;
                                  final time = await showTimePicker(
                                    context: ctx,
                                    initialTime: publishAt != null
                                        ? TimeOfDay.fromDateTime(publishAt!)
                                        : TimeOfDay.now(),
                                  );
                                  if (time == null) return;
                                  setDialogState(() {
                                    publishAt = DateTime(date.year, date.month,
                                        date.day, time.hour, time.minute);
                                  });
                                  saveDraft();
                                },
                              ),
                              const SizedBox(height: 12),
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                title: const Text('过期时间'),
                                subtitle: Text(expiresAt != null
                                    ? '${expiresAt!.toLocal()}'.substring(0, 16)
                                    : '永不过期'),
                                trailing: expiresAt != null
                                    ? IconButton(
                                        icon: const Icon(Icons.clear),
                                        onPressed: () => setDialogState(
                                            () => expiresAt = null),
                                      )
                                    : null,
                                onTap: () async {
                                  final date = await showDatePicker(
                                    context: ctx,
                                    initialDate: expiresAt ?? DateTime.now(),
                                    firstDate: DateTime.now(),
                                    lastDate: DateTime.now()
                                        .add(const Duration(days: 365 * 5)),
                                  );
                                  if (date == null || !ctx.mounted) return;
                                  final time = await showTimePicker(
                                    context: ctx,
                                    initialTime: expiresAt != null
                                        ? TimeOfDay.fromDateTime(expiresAt!)
                                        : const TimeOfDay(hour: 23, minute: 59),
                                  );
                                  if (time == null) return;
                                  setDialogState(() {
                                    expiresAt = DateTime(date.year, date.month,
                                        date.day, time.hour, time.minute);
                                  });
                                  saveDraft();
                                },
                              ),
                              const SizedBox(height: 12),
                              SwitchListTile(
                                value: includeNewUsers,
                                contentPadding: EdgeInsets.zero,
                                title: const Text('向公告发布后注册的新用户展示'),
                                subtitle: const Text('开启后，新注册用户也能看到此公告'),
                                onChanged: (value) async {
                                  setDialogState(() => includeNewUsers = value);
                                  await saveDraft();
                                },
                              ),
                            ],
                          ),
                        ),
                      ),
                      const Divider(height: 1),
                      Padding(
                        padding: const EdgeInsets.only(top: AppSpacing.sm),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: const Text('关闭'),
                            ),
                            const SizedBox(width: AppSpacing.sm),
                            FilledButton(
                              onPressed: () => Navigator.pop(ctx, true),
                              style: FilledButton.styleFrom(
                                backgroundColor: AppColors.brandPrimary,
                                foregroundColor: Colors.white,
                                minimumSize: const Size(84, 44),
                                shape: RoundedRectangleBorder(
                                  borderRadius:
                                      BorderRadius.circular(AppRadius.md),
                                ),
                              ),
                              child: Text(isEditing ? '保存' : '发布'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );

    titleCtrl.removeListener(draftListener);
    contentCtrl.removeListener(draftListener);

    if (!context.mounted) return;

    if (ok == true &&
        (titleCtrl.text.isNotEmpty || contentCtrl.text.isNotEmpty)) {
      final dio = context.read<AuthProvider>().dio;
      final postData = {
        'title': titleCtrl.text,
        'content': contentCtrl.text,
        'is_pinned': isPinned,
        'status': status,
        'display_mode': displayMode,
        'priority': priority,
        'publish_at': publishAt?.toUtc().toIso8601String(),
        'expires_at': expiresAt?.toUtc().toIso8601String(),
        'include_new_users': includeNewUsers,
      };
      try {
        if (isEditing) {
          await dio.put('${ApiConstants.noticesPath}/${announcement['id']}',
              data: postData);
        } else {
          await dio.post(ApiConstants.noticesPath, data: postData);
        }
        await prefs.remove('${draftKey}_title');
        await prefs.remove('${draftKey}_content');
        await prefs.remove('${draftKey}_pinned');
        await prefs.remove('${draftKey}_status');
        await prefs.remove('${draftKey}_display_mode');
        await prefs.remove('${draftKey}_priority');
        await prefs.remove('${draftKey}_include_new');
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(isEditing ? '公告已更新' : '公告已发布'),
            backgroundColor: Colors.green,
          ),
        );
        _refresh();
      } catch (_) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('操作失败'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Widget _announcementStatusChip(Map a, bool isDark) {
    final s = a['status']?.toString() ?? 'published';
    Color c;
    String label;
    switch (s) {
      case 'draft':
        c = Colors.grey;
        label = '草稿';
        break;
      case 'archived':
        c = Colors.brown;
        label = '归档';
        break;
      default:
        c = Colors.green;
        label = '已发布';
    }
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Text(label,
          style: AppTextStyles.labelMedium.copyWith(fontSize: 10, color: c)),
    );
  }

  Widget _announcementPriorityChip(Map a, bool isDark) {
    final p = a['priority']?.toString() ?? 'normal';
    Color c;
    String label;
    switch (p) {
      case 'urgent':
        c = Colors.red;
        label = '紧急';
        break;
      case 'important':
        c = Colors.orange;
        label = '重要';
        break;
      default:
        c = Colors.blue;
        label = '普通';
    }
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Text(label,
          style: AppTextStyles.labelMedium.copyWith(fontSize: 10, color: c)),
    );
  }

  Widget _buildAnnouncementState({
    required bool isDark,
    required IconData icon,
    required String title,
    required String message,
    VoidCallback? onPressed,
  }) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(
        parent: BouncingScrollPhysics(),
      ),
      padding: EdgeInsets.fromLTRB(
        AppSpacing.xxl,
        AppSpacing.section,
        AppSpacing.xxl,
        MediaQuery.viewPaddingOf(context).bottom + AppSpacing.xxl,
      ),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 300),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: isDark
                        ? AppColors.brandPrimary.withValues(alpha: 0.16)
                        : AppColors.brandPrimary.withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, color: AppColors.brandPrimary, size: 30),
                ),
                const SizedBox(height: AppSpacing.md),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: AppTextStyles.titleMedium.copyWith(
                    color: isDark ? Colors.white : AppColors.textPrimaryLight,
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: AppTextStyles.bodyMedium.copyWith(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.58)
                        : AppColors.textSecondaryLight,
                  ),
                ),
                if (onPressed != null) ...[
                  const SizedBox(height: AppSpacing.lg),
                  FilledButton.tonalIcon(
                    onPressed: onPressed,
                    style: FilledButton.styleFrom(
                      backgroundColor: isDark
                          ? AppColors.brandPrimary.withValues(alpha: 0.24)
                          : const Color(0xFFE5F4F1),
                      foregroundColor: isDark
                          ? const Color(0xFF8DE0D3)
                          : AppColors.brandPrimary,
                    ),
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: const Text('重新加载'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: const AppPageAppBar(title: Text('公告管理')),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.md,
                AppSpacing.lg,
                AppSpacing.sm,
              ),
              child: FilledButton.icon(
                onPressed: () => _showAnnouncementEditor(context),
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('发布公告'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(double.infinity, 48),
                  backgroundColor: AppColors.brandPrimary,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                ),
              ),
            ),
            Expanded(
              child: FutureBuilder(
                key: _futureKey,
                future: context
                    .read<AuthProvider>()
                    .dio
                    .get('${ApiConstants.noticesPath}/admin/list'),
                builder: (_, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snap.hasError) {
                    return _buildAnnouncementState(
                      isDark: isDark,
                      icon: Icons.cloud_off_rounded,
                      title: '公告加载失败',
                      message: '网络或服务暂时不可用，可以重新加载。',
                      onPressed: _refresh,
                    );
                  }
                  final list = (snap.data?.data as List?) ?? [];
                  if (list.isEmpty) {
                    return _buildAnnouncementState(
                      isDark: isDark,
                      icon: Icons.campaign_outlined,
                      title: '暂无公告',
                      message: '发布一条公告后，它会显示在这里统一管理。',
                    );
                  }
                  return RefreshIndicator(
                    onRefresh: () async => _refresh(),
                    child: Scrollbar(
                      thumbVisibility: true,
                      child: ListView.builder(
                        keyboardDismissBehavior:
                            ScrollViewKeyboardDismissBehavior.onDrag,
                        physics: const AlwaysScrollableScrollPhysics(
                          parent: BouncingScrollPhysics(),
                        ),
                        padding: EdgeInsets.fromLTRB(
                          AppSpacing.lg,
                          AppSpacing.xs,
                          AppSpacing.lg,
                          MediaQuery.viewPaddingOf(context).bottom +
                              AppSpacing.xxl,
                        ),
                        itemCount: list.length,
                        itemBuilder: (_, i) {
                          final a = list[i];
                          final title = a['title']?.toString() ?? '';
                          final content = a['content']?.toString() ?? '';
                          final isPinned = a['is_pinned'] == true;
                          return Card(
                            margin:
                                const EdgeInsets.only(bottom: AppSpacing.sm),
                            elevation: 0,
                            color: isDark
                                ? AppColors.surfaceSecondaryDark
                                : AppColors.surfaceSecondaryLight,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(AppRadius.lg),
                              side: BorderSide(
                                color: isDark
                                    ? Colors.white.withValues(alpha: 0.08)
                                    : AppColors.borderSubtleLight,
                              ),
                            ),
                            child: InkWell(
                              onTap: () => _showAnnouncementEditor(
                                context,
                                announcement: a,
                              ),
                              borderRadius: BorderRadius.circular(AppRadius.lg),
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  AppSpacing.md,
                                  AppSpacing.md,
                                  AppSpacing.sm,
                                  AppSpacing.md,
                                ),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              _announcementStatusChip(
                                                  a, isDark),
                                              const SizedBox(
                                                  width: AppSpacing.xs),
                                              _announcementPriorityChip(
                                                  a, isDark),
                                              if (isPinned) ...[
                                                const SizedBox(
                                                    width: AppSpacing.xs),
                                                const Icon(
                                                  Icons.push_pin_rounded,
                                                  size: 15,
                                                  color: AppColors.brandPrimary,
                                                ),
                                              ],
                                            ],
                                          ),
                                          const SizedBox(height: AppSpacing.sm),
                                          Text(
                                            title,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            style: AppTextStyles.titleMedium
                                                .copyWith(
                                              fontSize: 16,
                                              color: isDark
                                                  ? Colors.white
                                                  : AppColors.textPrimaryLight,
                                            ),
                                          ),
                                          if (content.isNotEmpty) ...[
                                            const SizedBox(
                                                height: AppSpacing.xs),
                                            Text(
                                              content,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              style: AppTextStyles.bodyMedium
                                                  .copyWith(
                                                color: isDark
                                                    ? Colors.white.withValues(
                                                        alpha: 0.62,
                                                      )
                                                    : AppColors
                                                        .textSecondaryLight,
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                    PopupMenuButton<String>(
                                      tooltip: '更多操作',
                                      padding: EdgeInsets.zero,
                                      icon: const Icon(Icons.more_vert_rounded),
                                      itemBuilder: (_) => [
                                        const PopupMenuItem(
                                          value: 'edit',
                                          child: Text('编辑'),
                                        ),
                                        PopupMenuItem(
                                          value: 'pin',
                                          child: Text(isPinned ? '取消置顶' : '置顶'),
                                        ),
                                        const PopupMenuItem(
                                          value: 'delete',
                                          child: Text(
                                            '删除',
                                            style: TextStyle(color: Colors.red),
                                          ),
                                        ),
                                      ],
                                      onSelected: (v) async {
                                        final dio =
                                            context.read<AuthProvider>().dio;
                                        if (v == 'edit') {
                                          await _showAnnouncementEditor(
                                            context,
                                            announcement: a,
                                          );
                                        } else if (v == 'pin') {
                                          try {
                                            await dio.put(
                                              '${ApiConstants.noticesPath}/${a['id']}',
                                              data: {'is_pinned': !isPinned},
                                            );
                                            if (!context.mounted) return;
                                            ScaffoldMessenger.of(context)
                                                .showSnackBar(
                                              SnackBar(
                                                content: Text(isPinned
                                                    ? '已取消置顶'
                                                    : '已置顶公告'),
                                                backgroundColor:
                                                    AppColors.brandPrimary,
                                              ),
                                            );
                                            _refresh();
                                          } catch (_) {}
                                        } else if (v == 'delete') {
                                          try {
                                            await dio.delete(
                                                '${ApiConstants.noticesPath}/${a['id']}');
                                            if (!context.mounted) return;
                                            ScaffoldMessenger.of(context)
                                                .showSnackBar(
                                              const SnackBar(
                                                content: Text('公告已删除'),
                                                backgroundColor:
                                                    AppColors.brandPrimary,
                                              ),
                                            );
                                            _refresh();
                                          } catch (_) {}
                                        }
                                      },
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

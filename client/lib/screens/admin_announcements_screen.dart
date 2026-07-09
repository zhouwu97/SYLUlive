import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../config/api_constants.dart';
import '../providers/auth_provider.dart';

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
    final prefs = await SharedPreferences.getInstance();
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

    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Text(isEditing ? '编辑公告' : '发布公告'),
          content: SingleChildScrollView(
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
                  value: status,
                  decoration: const InputDecoration(
                    labelText: '发布状态',
                    border: OutlineInputBorder(),
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                  ),
                  items: const [
                    DropdownMenuItem(value: 'draft', child: Text('草稿')),
                    DropdownMenuItem(value: 'published', child: Text('已发布')),
                    DropdownMenuItem(value: 'archived', child: Text('已归档')),
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
                  value: displayMode,
                  decoration: const InputDecoration(
                    labelText: '展示方式',
                    border: OutlineInputBorder(),
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                  ),
                  items: const [
                    DropdownMenuItem(value: 'center', child: Text('公告中心')),
                    DropdownMenuItem(value: 'banner', child: Text('首页横幅')),
                    DropdownMenuItem(value: 'modal', child: Text('弹窗提醒')),
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
                  value: priority,
                  decoration: const InputDecoration(
                    labelText: '优先级',
                    border: OutlineInputBorder(),
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                  ),
                  items: const [
                    DropdownMenuItem(value: 'normal', child: Text('普通')),
                    DropdownMenuItem(value: 'important', child: Text('重要')),
                    DropdownMenuItem(value: 'urgent', child: Text('紧急')),
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
                          onPressed: () =>
                              setDialogState(() => publishAt = null),
                        )
                      : null,
                  onTap: () async {
                    final date = await showDatePicker(
                      context: ctx,
                      initialDate: publishAt ?? DateTime.now(),
                      firstDate: DateTime.now(),
                      lastDate: DateTime.now().add(const Duration(days: 365)),
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
                      publishAt = DateTime(date.year, date.month, date.day,
                          time.hour, time.minute);
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
                          onPressed: () =>
                              setDialogState(() => expiresAt = null),
                        )
                      : null,
                  onTap: () async {
                    final date = await showDatePicker(
                      context: ctx,
                      initialDate: expiresAt ?? DateTime.now(),
                      firstDate: DateTime.now(),
                      lastDate:
                          DateTime.now().add(const Duration(days: 365 * 5)),
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
                      expiresAt = DateTime(date.year, date.month, date.day,
                          time.hour, time.minute);
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
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('关闭'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(isEditing ? '保存' : '发布'),
            ),
          ],
        ),
      ),
    );

    titleCtrl.removeListener(draftListener);
    contentCtrl.removeListener(draftListener);

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
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(isEditing ? '公告已更新' : '公告已发布'),
              backgroundColor: Colors.green,
            ),
          );
          _refresh();
        }
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('操作失败'), backgroundColor: Colors.red),
          );
        }
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
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: c.withOpacity(0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(label,
          style:
              TextStyle(fontSize: 10, color: c, fontWeight: FontWeight.w600)),
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
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: c.withOpacity(0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(label,
          style:
              TextStyle(fontSize: 10, color: c, fontWeight: FontWeight.w600)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(title: const Text('公告管理')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: ElevatedButton.icon(
              onPressed: () => _showAnnouncementEditor(context),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('发布公告'),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(double.infinity, 44),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
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
                if (!snap.hasData)
                  return const Center(child: CircularProgressIndicator());
                final list = (snap.data!.data as List?) ?? [];
                if (list.isEmpty) {
                  return Center(
                    child: Text(
                      '暂无公告',
                      style: TextStyle(
                          color: isDark ? Colors.white54 : Colors.grey[600]),
                    ),
                  );
                }
                return ListView.builder(
                  physics: const AlwaysScrollableScrollPhysics(
                      parent: BouncingScrollPhysics()),
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  itemCount: list.length,
                  itemBuilder: (_, i) {
                    final a = list[i];
                    return Card(
                      color: isDark ? Colors.grey[850] : Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                      margin: const EdgeInsets.only(bottom: 10),
                      child: ListTile(
                        onTap: () =>
                            _showAnnouncementEditor(context, announcement: a),
                        title: Row(
                          children: [
                            _announcementStatusChip(a, isDark),
                            const SizedBox(width: 6),
                            _announcementPriorityChip(a, isDark),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                a['title'] ?? '',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        subtitle: Text(
                          a['content'] ?? '',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: PopupMenuButton(
                          itemBuilder: (_) => [
                            const PopupMenuItem(
                                value: 'edit', child: Text('编辑')),
                            PopupMenuItem(
                              value: 'pin',
                              child:
                                  Text(a['is_pinned'] == true ? '取消置顶' : '置顶'),
                            ),
                            const PopupMenuItem(
                              value: 'delete',
                              child: Text('删除',
                                  style: TextStyle(color: Colors.red)),
                            ),
                          ],
                          onSelected: (v) async {
                            final dio = context.read<AuthProvider>().dio;
                            if (v == 'edit') {
                              await _showAnnouncementEditor(context,
                                  announcement: a);
                            } else if (v == 'pin') {
                              try {
                                await dio.put(
                                  '${ApiConstants.noticesPath}/${a['id']}',
                                  data: {
                                    'is_pinned': !(a['is_pinned'] == true)
                                  },
                                );
                                if (mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(a['is_pinned'] == true
                                          ? '已取消置顶'
                                          : '已置顶公告'),
                                      backgroundColor: Colors.green,
                                    ),
                                  );
                                  _refresh();
                                }
                              } catch (_) {}
                            } else if (v == 'delete') {
                              try {
                                await dio.delete(
                                    '${ApiConstants.noticesPath}/${a['id']}');
                                if (mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                        content: Text('公告已删除'),
                                        backgroundColor: Colors.green),
                                  );
                                  _refresh();
                                }
                              } catch (_) {}
                            }
                          },
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

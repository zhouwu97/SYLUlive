import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

/// 超级管理员的 APK 发布管理页。APK 先创建不可下载的 draft，再由管理员显式
/// 发布；这样上传中断或元数据填写错误都不会让客户端拿到半成品安装包。
class AppReleaseAdminTab extends StatefulWidget {
  final Dio dio;

  const AppReleaseAdminTab({super.key, required this.dio});

  @override
  State<AppReleaseAdminTab> createState() => _AppReleaseAdminTabState();
}

class _AppReleaseAdminTabState extends State<AppReleaseAdminTab> {
  List<Map<String, dynamic>> _releases = const [];
  bool _loading = true;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    try {
      final response = await widget.dio.get('/super/app-releases');
      final raw = response.data is Map ? (response.data as Map)['items'] : null;
      final releases = (raw is List ? raw : const [])
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
      if (mounted) setState(() => _releases = releases);
    } catch (error) {
      _showMessage(_apiErrorMessage(error, '读取应用版本失败'), isError: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        RefreshIndicator(
          onRefresh: _load,
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _releases.isEmpty
                  ? ListView(
                      children: const [
                        SizedBox(height: 180),
                        Center(child: Text('暂无应用版本')),
                      ],
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
                      itemCount: _releases.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, index) =>
                          _buildReleaseItem(_releases[index]),
                    ),
        ),
        Positioned(
          right: 16,
          bottom: 16,
          child: FloatingActionButton(
            heroTag: 'app_release_create',
            tooltip: '上传应用版本',
            onPressed: _submitting ? null : _showCreateDialog,
            child: const Icon(Icons.add),
          ),
        ),
      ],
    );
  }

  Widget _buildReleaseItem(Map<String, dynamic> release) {
    final status = release['status']?.toString() ?? '';
    final versionName = release['version_name']?.toString() ?? '-';
    final versionCode = release['version_code']?.toString() ?? '-';
    final title = release['title']?.toString() ?? '未命名版本';
    final minimum =
        release['minimum_supported_version_code']?.toString() ?? '-';
    final size = _formatBytes(_asInt(release['file_size']));
    final theme = Theme.of(context);

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      leading: Icon(
        status == 'published'
            ? Icons.verified_rounded
            : status == 'withdrawn'
                ? Icons.archive_outlined
                : Icons.edit_note_rounded,
        color: _statusColor(status, theme),
      ),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '$versionName+$versionCode  ·  最低支持 $minimum\n$status  ·  $size',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      isThreeLine: true,
      trailing: PopupMenuButton<_ReleaseAction>(
        tooltip: '版本操作',
        onSelected: (action) => _handleAction(release, action),
        itemBuilder: (_) => [
          if (status == 'draft') ...[
            const PopupMenuItem(
                value: _ReleaseAction.edit, child: Text('编辑草稿')),
            const PopupMenuItem(
                value: _ReleaseAction.publish, child: Text('发布')),
            const PopupMenuItem(
                value: _ReleaseAction.delete, child: Text('删除草稿')),
          ],
          if (status == 'published') ...[
            const PopupMenuItem(
                value: _ReleaseAction.edit, child: Text('调整最低支持版本')),
            const PopupMenuItem(
                value: _ReleaseAction.withdraw, child: Text('下架')),
          ],
        ],
      ),
    );
  }

  Future<void> _handleAction(
    Map<String, dynamic> release,
    _ReleaseAction action,
  ) async {
    switch (action) {
      case _ReleaseAction.edit:
        await _showEditDialog(release);
      case _ReleaseAction.publish:
        await _confirmAndRun(
          title: '发布 ${release['version_name']}+${release['version_code']}？',
          content: '发布后客户端将能检测并下载此 APK。请确认版本号、安装包和最低支持构建号均正确。',
          actionText: '发布',
          action: () =>
              widget.dio.post('/super/app-releases/${release['id']}/publish'),
        );
      case _ReleaseAction.withdraw:
        await _confirmAndRun(
          title: '下架 ${release['version_name']}+${release['version_code']}？',
          content: '下架后不再允许新客户端下载。系统至少必须保留一个已发布版本。',
          actionText: '下架',
          destructive: true,
          action: () =>
              widget.dio.post('/super/app-releases/${release['id']}/withdraw'),
        );
      case _ReleaseAction.delete:
        await _confirmAndRun(
          title: '删除草稿？',
          content: '将同时删除服务器中的未发布 APK，此操作不可恢复。',
          actionText: '删除',
          destructive: true,
          action: () =>
              widget.dio.delete('/super/app-releases/${release['id']}'),
        );
    }
  }

  Future<void> _showCreateDialog() async {
    PlatformFile? apk;
    final versionName = TextEditingController();
    final versionCode = TextEditingController();
    final title = TextEditingController();
    final changelog = TextEditingController();
    final minimum = TextEditingController();
    final actionUrl = TextEditingController();
    String selectedPlatform = 'android';
    String selectedDeliveryMode = 'direct_package';
    final formKey = GlobalKey<FormState>();

    final payload = await showDialog<_DraftPayload>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('上传应用版本'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Form(
                key: formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DropdownButtonFormField<String>(
                      value: selectedPlatform,
                      decoration: const InputDecoration(labelText: '发布平台'),
                      items: const [
                        DropdownMenuItem(value: 'android', child: Text('Android')),
                        DropdownMenuItem(value: 'ohos', child: Text('HarmonyOS')),
                      ],
                      onChanged: (v) {
                        if (v != null) {
                          setDialogState(() {
                            selectedPlatform = v;
                            if (v == 'ohos') {
                              selectedDeliveryMode = 'external_market';
                            }
                          });
                        }
                      },
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      value: selectedDeliveryMode,
                      decoration: const InputDecoration(labelText: '交付模式'),
                      items: const [
                        DropdownMenuItem(value: 'direct_package', child: Text('直接安装包')),
                        DropdownMenuItem(value: 'external_market', child: Text('外部市场')),
                      ],
                      onChanged: selectedPlatform == 'ohos'
                          ? null
                          : (v) {
                              if (v != null) {
                                setDialogState(() => selectedDeliveryMode = v);
                              }
                            },
                    ),
                    const SizedBox(height: 12),
                    if (selectedDeliveryMode == 'direct_package') ...[
                      OutlinedButton.icon(
                        onPressed: () async {
                          final selected = await FilePicker.platform.pickFiles(
                            type: FileType.custom,
                            allowedExtensions: const ['apk'],
                            allowMultiple: false,
                            withData: false,
                          );
                          final file = selected?.files.singleOrNull;
                          if (file == null) return;
                          if (file.path == null || file.size <= 0) {
                            if (dialogContext.mounted) {
                              ScaffoldMessenger.of(dialogContext).showSnackBar(
                                const SnackBar(
                                    content: Text('无法读取 APK 文件，请重新选择')),
                              );
                            }
                            return;
                          }
                          setDialogState(() => apk = file);
                        },
                        icon: const Icon(Icons.upload_file_outlined),
                        label: Text(apk == null ? '选择 APK' : apk!.name),
                      ),
                      const SizedBox(height: 12),
                    ],
                    if (selectedDeliveryMode == 'external_market') ...[
                      _field(actionUrl, '跳转链接 (以 http:// 或 https:// 开头)'),
                      const SizedBox(height: 12),
                    ],
                    _field(versionName, '展示版本号，例如 1.6.3'),
                    _field(versionCode, '构建号，例如 1603', numeric: true),
                    _field(title, '更新标题'),
                    _field(changelog, '更新说明', maxLines: 4),
                    _field(minimum, '最低支持构建号', numeric: true),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                if (!formKey.currentState!.validate()) return;
                if (selectedDeliveryMode == 'direct_package' && apk == null) {
                  ScaffoldMessenger.of(dialogContext).showSnackBar(
                    const SnackBar(content: Text('直接安装包模式下必须选择 APK')),
                  );
                  return;
                }
                if (selectedDeliveryMode == 'external_market' && actionUrl.text.trim().isEmpty) {
                  ScaffoldMessenger.of(dialogContext).showSnackBar(
                    const SnackBar(content: Text('外部市场模式下必须填写跳转链接')),
                  );
                  return;
                }
                final code = int.tryParse(versionCode.text.trim());
                final min = int.tryParse(minimum.text.trim());
                if (code == null || min == null || min > code) {
                  ScaffoldMessenger.of(dialogContext).showSnackBar(
                    const SnackBar(content: Text('最低支持构建号必须不大于当前构建号')),
                  );
                  return;
                }
                Navigator.pop(
                  dialogContext,
                  _DraftPayload(
                    apk: apk,
                    platform: selectedPlatform,
                    deliveryMode: selectedDeliveryMode,
                    actionUrl: actionUrl.text.trim(),
                    versionName: versionName.text.trim(),
                    versionCode: code,
                    title: title.text.trim(),
                    changelog: changelog.text.trim(),
                    minimumSupportedVersionCode: min,
                  ),
                );
              },
              child: const Text('创建草稿'),
            ),
          ],
        ),
      ),
    );
    versionName.dispose();
    versionCode.dispose();
    title.dispose();
    changelog.dispose();
    minimum.dispose();
    actionUrl.dispose();
    if (payload == null) return;

    final path = payload.apk?.path;
    if (payload.deliveryMode == 'direct_package' && path == null) {
      _showMessage('APK 路径不可用，请重新选择', isError: true);
      return;
    }
    await _run(() async {
      final Map<String, dynamic> data = {
        'platform': payload.platform,
        'channel': 'stable',
        'delivery_mode': payload.deliveryMode,
        'action_url': payload.actionUrl,
        'version_name': payload.versionName,
        'version_code': payload.versionCode.toString(),
        'title': payload.title,
        'changelog': payload.changelog,
        'minimum_supported_version_code':
            payload.minimumSupportedVersionCode.toString(),
      };
      if (payload.deliveryMode == 'direct_package') {
        data['apk'] = await MultipartFile.fromFile(path!, filename: payload.apk!.name);
      }
      await widget.dio.post(
        '/super/app-releases',
        data: FormData.fromMap(data),
      );
      _showMessage('草稿已创建，请核对后发布');
    });
  }

  Future<void> _showEditDialog(Map<String, dynamic> release) async {
    final isDraft = release['status'] == 'draft';
    final title =
        TextEditingController(text: release['title']?.toString() ?? '');
    final changelog =
        TextEditingController(text: release['changelog']?.toString() ?? '');
    final minimum = TextEditingController(
      text: release['minimum_supported_version_code']?.toString() ?? '',
    );
    final formKey = GlobalKey<FormState>();
    final update = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(isDraft ? '编辑草稿' : '调整最低支持版本'),
        content: SizedBox(
          width: 420,
          child: Form(
            key: formKey,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isDraft) _field(title, '更新标题'),
                  if (isDraft) _field(changelog, '更新说明', maxLines: 4),
                  _field(minimum, '最低支持构建号', numeric: true),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (!formKey.currentState!.validate()) return;
              final min = int.tryParse(minimum.text.trim());
              final versionCode = _asInt(release['version_code']);
              if (min == null || min <= 0 || min > versionCode) return;
              Navigator.pop(dialogContext, {
                if (isDraft) 'title': title.text.trim(),
                if (isDraft) 'changelog': changelog.text.trim(),
                'minimum_supported_version_code': min,
              });
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    title.dispose();
    changelog.dispose();
    minimum.dispose();
    if (update == null) return;
    await _run(() async {
      await widget.dio
          .patch('/super/app-releases/${release['id']}', data: update);
      _showMessage('版本策略已更新');
    });
  }

  TextFormField _field(
    TextEditingController controller,
    String label, {
    bool numeric = false,
    int maxLines = 1,
  }) {
    return TextFormField(
      controller: controller,
      keyboardType: numeric ? TextInputType.number : TextInputType.text,
      maxLines: maxLines,
      validator: (value) =>
          value == null || value.trim().isEmpty ? '请填写$label' : null,
      decoration: InputDecoration(labelText: label),
    );
  }

  Future<void> _confirmAndRun({
    required String title,
    required String content,
    required String actionText,
    required Future<void> Function() action,
    bool destructive = false,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: destructive
                ? FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error)
                : null,
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(actionText),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _run(action);
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_submitting) return;
    setState(() => _submitting = true);
    try {
      await action();
      await _load();
    } catch (error) {
      _showMessage(_apiErrorMessage(error, '操作失败'), isError: true);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _showMessage(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Theme.of(context).colorScheme.error : null,
      ),
    );
  }

  int _asInt(dynamic value) =>
      value is int ? value : int.tryParse('$value') ?? 0;

  Color _statusColor(String status, ThemeData theme) => switch (status) {
        'published' => Colors.green,
        'withdrawn' => theme.colorScheme.outline,
        _ => theme.colorScheme.primary,
      };

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '大小未知';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}

enum _ReleaseAction { edit, publish, withdraw, delete }

class _DraftPayload {
  final PlatformFile? apk;
  final String platform;
  final String deliveryMode;
  final String actionUrl;
  final String versionName;
  final int versionCode;
  final String title;
  final String changelog;
  final int minimumSupportedVersionCode;

  const _DraftPayload({
    required this.apk,
    required this.platform,
    required this.deliveryMode,
    required this.actionUrl,
    required this.versionName,
    required this.versionCode,
    required this.title,
    required this.changelog,
    required this.minimumSupportedVersionCode,
  });
}

String _apiErrorMessage(Object error, String fallback) {
  if (error is DioException) {
    final data = error.response?.data;
    if (data is Map) {
      final message = data['message'] ?? data['error'];
      if (message != null) return message.toString();
    }
  }
  return fallback;
}

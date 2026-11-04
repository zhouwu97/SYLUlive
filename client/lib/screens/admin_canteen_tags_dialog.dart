import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/canteen.dart';
import '../providers/canteen_provider.dart';
import '../providers/auth_provider.dart';
import '../widgets/app_dialog.dart';
import '../theme/app_spacing.dart';
import 'canteen_review_editor_screen.dart' show kCanteenTagOptions;

class AdminCanteenTagsDialog extends StatefulWidget {
  const AdminCanteenTagsDialog({super.key, required this.canteen});
  final Canteen canteen;

  @override
  State<AdminCanteenTagsDialog> createState() => _AdminCanteenTagsDialogState();
}

class _AdminCanteenTagsDialogState extends State<AdminCanteenTagsDialog> {
  bool loading = true, saving = false, automatic = true, loadFailed = false;
  String? error;
  String area = '', floor = '';
  final selected = <String>[];
  AuthProvider? _auth;
  int? _sessionGeneration;

  bool get _sessionValid =>
      _auth == null ||
      (_auth!.sessionGeneration == _sessionGeneration &&
          _auth!.user?.isAdmin == true);

  @override
  void initState() {
    super.initState();
    _auth = context.read<AuthProvider?>();
    _sessionGeneration = _auth?.sessionGeneration;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      loading = true;
      loadFailed = false;
      error = null;
    });
    try {
      final data = await context
          .read<CanteenProvider>()
          .getDisplayTags(widget.canteen.id);
      if (!mounted || !_sessionValid) return;
      area = data['location_area'] as String? ?? '';
      floor = data['location_floor'] as String? ?? '';
      automatic = data['tags'] == null;
      selected
        ..clear()
        ..addAll((data['tags'] as List? ?? []).cast<String>());
    } on DioException catch (e) {
      if (!mounted) return;
      loadFailed = true;
      error = _requestError(e, loading: true);
    } catch (_) {
      if (!mounted) return;
      loadFailed = true;
      error = '加载标签失败，请重试';
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _save() async {
    if (!_sessionValid || saving) return;
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await context.read<CanteenProvider>().updateDisplayTags(
          widget.canteen.id, area, floor, automatic ? null : selected);
      if (mounted && _sessionValid) Navigator.pop(context, true);
    } on DioException catch (e) {
      if (mounted) {
        setState(() => error = _requestError(e, loading: false));
      }
    } catch (_) {
      if (mounted) setState(() => error = '保存失败，请重试');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  String _requestError(DioException exception, {required bool loading}) {
    final status = exception.response?.statusCode;
    final data = exception.response?.data;
    if (status == 404 && data is! Map) {
      return '当前服务尚未支持店铺标签管理，请更新服务后重试';
    }
    if (status == 401) return '登录已失效，请重新登录后再试';
    if (status == 403) return '当前账号没有管理店铺标签的权限';
    if (data is Map &&
        status != null &&
        status >= 400 &&
        (!loading || status < 500)) {
      final message = data['message'] ?? data['error'];
      if (message is String && message.trim().isNotEmpty) return message;
    }
    return loading ? '加载标签失败，请重试' : '保存失败，请重试';
  }

  @override
  Widget build(BuildContext context) {
    context.watch<AuthProvider?>();
    final sessionValid = _sessionValid;
    return PopScope(
      canPop: !saving,
      child: AppAlertDialog(
        title: const Text('店铺标签'),
        content: !sessionValid
            ? const Text('账号或管理权限已变更，请关闭后重新打开')
            : loading
                ? const SizedBox(
                    height: 80,
                    child: Center(child: CircularProgressIndicator()))
                : loadFailed
                    ? Column(mainAxisSize: MainAxisSize.min, children: [
                        Text(error!),
                        TextButton(onPressed: _load, child: const Text('重试'))
                      ])
                    : SingleChildScrollView(
                        child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                            Text(widget.canteen.name,
                                style: Theme.of(context).textTheme.titleSmall),
                            const SizedBox(height: AppSpacing.lg),
                            DropdownButtonFormField<String>(
                                initialValue: area,
                                decoration:
                                    const InputDecoration(labelText: '食堂'),
                                items: const ['', '一食堂', '二食堂']
                                    .map((v) => DropdownMenuItem(
                                        value: v,
                                        child: Text(v.isEmpty ? '未设置' : v)))
                                    .toList(),
                                onChanged: saving
                                    ? null
                                    : (v) => setState(() => area = v ?? '')),
                            const SizedBox(height: AppSpacing.lg),
                            DropdownButtonFormField<String>(
                                initialValue: floor,
                                decoration:
                                    const InputDecoration(labelText: '楼层'),
                                items: const ['', '一楼', '二楼']
                                    .map((v) => DropdownMenuItem(
                                        value: v,
                                        child: Text(v.isEmpty ? '未设置' : v)))
                                    .toList(),
                                onChanged: saving
                                    ? null
                                    : (v) => setState(() => floor = v ?? '')),
                            const SizedBox(height: AppSpacing.sm),
                            SwitchListTile(
                                contentPadding: EdgeInsets.zero,
                                title: const Text('自动汇总评价标签'),
                                subtitle: const Text('关闭后可手动选择最多三个展示标签'),
                                value: automatic,
                                onChanged: saving
                                    ? null
                                    : (v) => setState(() => automatic = v)),
                            if (!automatic)
                              Wrap(spacing: 8, children: [
                                for (final tag in kCanteenTagOptions)
                                  FilterChip(
                                      label: Text(tag.label),
                                      selected: selected.contains(tag.key),
                                      onSelected: saving ||
                                              (!selected.contains(tag.key) &&
                                                  selected.length >= 3)
                                          ? null
                                          : (value) => setState(() {
                                                if (value &&
                                                    selected.length < 3) {
                                                  selected.add(tag.key);
                                                } else if (!value) {
                                                  selected.remove(tag.key);
                                                }
                                              }))
                              ]),
                            if (!automatic)
                              Text('已选择 ${selected.length}/3 个标签，按选择顺序展示'),
                            if (!automatic) const Text('未选择时不显示评价标签'),
                            if (error != null)
                              Text(error!,
                                  style: TextStyle(
                                      color:
                                          Theme.of(context).colorScheme.error)),
                          ])),
        actions: [
          TextButton(
              style: TextButton.styleFrom(minimumSize: const Size(64, 44)),
              onPressed: saving ? null : () => Navigator.pop(context),
              child: const Text('取消')),
          FilledButton(
              style: FilledButton.styleFrom(
                minimumSize: const Size(64, 44),
                textStyle: Theme.of(context).textTheme.labelLarge,
              ),
              onPressed: loading || saving || loadFailed || !sessionValid
                  ? null
                  : _save,
              child: Text(saving ? '保存中…' : '保存'))
        ],
      ),
    );
  }
}

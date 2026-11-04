import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../providers/auth_provider.dart';
import '../../../services/publish_session_scope.dart';
import '../../../theme/app_spacing.dart';
import '../../../widgets/app_choice_chip.dart';
import '../../../widgets/app_dialog.dart';
import '../../../widgets/security_session_guard.dart';
import '../data/emoji_pack_local_store.dart';
import '../data/emoji_submission_repository.dart';
import '../domain/emoji_pack.dart';
import '../domain/emoji_pack_installation.dart';
import 'emoji_ui.dart';
import 'emoji_submission_image.dart';

/// 会话失效后页面不可重新认领，连同正在展示的大图和确认弹窗一起隐藏旧数据。
abstract class _EmojiSubmissionState<T extends StatefulWidget>
    extends State<T> {
  AuthProvider? auth;
  PublishSessionScope? session;
  EmojiSubmissionRepository? repository;
  CancelToken token = CancelToken();
  bool invalidated = false;
  bool get requireAdmin => false;
  bool get current =>
      mounted &&
      !invalidated &&
      auth != null &&
      session != null &&
      SecuritySessionGuard.owns(auth!, session!, requireAdmin: requireAdmin);
  @override
  void initState() {
    super.initState();
    auth = context.read<AuthProvider?>();
    final user = auth?.user;
    if (auth?.isLoggedIn == true && user != null) {
      session = PublishSessionScope(
          accountId: user.id, accountSessionEpoch: auth!.accountSessionEpoch);
      repository = EmojiSubmissionRepository(auth!.dio);
    }
    auth?.addListener(_sessionChanged);
  }

  void _sessionChanged() {
    if (current || invalidated) return;
    invalidated = true;
    token.cancel('账号或权限已变化');
    if (mounted) setState(() {});
  }

  String failureMessage(Object error) {
    if (error is DioException &&
        (error.response?.statusCode == 401 ||
            requireAdmin && error.response?.statusCode == 403)) {
      invalidated = true;
      token.cancel('账号或权限已失效');
    }
    return emojiSubmissionError(error);
  }

  CancelToken nextRequest() {
    token.cancel('请求已替换');
    return token = CancelToken();
  }

  Widget get permissionState => EmojiStateView(
      icon: Icons.lock_outline,
      title: invalidated
          ? '账号或权限已变化，请返回重新打开'
          : requireAdmin
              ? '需要管理员权限'
              : '请登录后重新打开我的投稿');

  @override
  void dispose() {
    token.cancel('页面已关闭');
    auth?.removeListener(_sessionChanged);
    super.dispose();
  }
}

class EmojiSubmissionsScreen extends StatefulWidget {
  const EmojiSubmissionsScreen({super.key, this.store, this.admin = false});
  final EmojiPackLocalStore? store;
  final bool admin;
  @override
  State<EmojiSubmissionsScreen> createState() => _EmojiSubmissionsScreenState();
}

class _EmojiSubmissionsScreenState
    extends _EmojiSubmissionState<EmojiSubmissionsScreen> {
  @override
  bool get requireAdmin => widget.admin;
  List<EmojiSubmission>? _items;
  String? _error;
  String? _filter;
  int _page = 0, _total = 0;
  bool _loading = false;
  bool _retryMore = false;
  @override
  void initState() {
    super.initState();
    _filter = widget.admin ? 'pending' : null;
    if (current) unawaited(_load());
  }

  Future<void> _load({bool more = false}) async {
    if (!current || more && _loading) return;
    final request = nextRequest();
    setState(() {
      _loading = true;
      _retryMore = more;
      _error = null;
    });
    try {
      final page = more ? _page + 1 : 1;
      final result = await repository!.list(
          session: session!,
          token: request,
          admin: widget.admin,
          status: _filter,
          page: page);
      if (!current || request.isCancelled) return;
      setState(() {
        _items = more ? [...?_items, ...result.items] : result.items;
        _page = page;
        _total = result.total;
      });
    } catch (error) {
      if (current && !request.isCancelled) {
        setState(() => _error = failureMessage(error));
      }
    } finally {
      if (current && !request.isCancelled) setState(() => _loading = false);
    }
  }

  Future<void> _open(EmojiSubmission item) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) =>
            EmojiSubmissionDetailScreen(id: item.id, admin: widget.admin)));
    if (current) await _load();
  }

  Future<void> _upload() async {
    if (!current || widget.store == null) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => EmojiSubmissionUploadScreen(store: widget.store!)));
    if (current) await _load();
  }

  @override
  Widget build(BuildContext context) => EmojiPageScaffold(
      title: widget.admin ? '表情包审核' : '我的投稿',
      actions: [
        if (!widget.admin && current && widget.store != null)
          TextButton(onPressed: _upload, child: const Text('上传'))
      ],
      body: !current
          ? permissionState
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  children: [
                    Text(
                        widget.admin
                            ? '预览全部表情，确认内容和分享授权后处理。'
                            : '分享喜欢的表情包，审核通过后大家就能下载。',
                        style: Theme.of(context).textTheme.bodyMedium),
                    const SizedBox(height: AppSpacing.md),
                    Wrap(
                        spacing: AppSpacing.sm,
                        runSpacing: AppSpacing.xs,
                        children: [
                          if (!widget.admin) _chip(null, '全部'),
                          for (final status in [
                            'pending',
                            'published',
                            'rejected',
                            'unpublished'
                          ])
                            _chip(status, emojiSubmissionStatus(status)),
                        ]),
                    if (_error != null)
                      EmojiInlineError(
                          message: _error!,
                          onRetry: () => _load(more: _retryMore)),
                    if (_loading) const LinearProgressIndicator(),
                    if (_items?.isEmpty == true)
                      EmojiStateView(
                          title: widget.admin
                              ? '暂无${emojiSubmissionStatus(_filter!)}的表情包'
                              : '暂无投稿',
                          detail: widget.admin
                              ? '其他审核状态可在上方切换。'
                              : '先导入喜欢的表情包，再来这里上传分享。',
                          action: widget.admin || widget.store == null
                              ? null
                              : OutlinedButton.icon(
                                  onPressed: _upload,
                                  icon: const Icon(Icons.cloud_upload_outlined),
                                  label: const Text('上传表情包'))),
                    for (final item in _items ?? <EmojiSubmission>[])
                      ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                              vertical: AppSpacing.sm),
                          title: Text(item.name),
                          subtitle: Text(
                              '${emojiSubmissionStatus(item.status)} · ${item.assetCount} 个表情'
                              '${item.reviewReason.isEmpty ? '' : '\n${item.reviewReason}'}'),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => _open(item)),
                    if (_items != null && _items!.length < _total)
                      TextButton(
                          onPressed: _loading ? null : () => _load(more: true),
                          child: const Text('加载更多')),
                  ])));

  Widget _chip(String? status, String label) => AppChoiceChip(
      label: Text(label),
      selected: _filter == status,
      onSelected: (_) {
        setState(() {
          _filter = status;
          _items = null;
          _page = 0;
        });
        unawaited(_load());
      });
}

class EmojiSubmissionUploadScreen extends StatefulWidget {
  const EmojiSubmissionUploadScreen({super.key, required this.store});
  final EmojiPackLocalStore store;
  @override
  State<EmojiSubmissionUploadScreen> createState() =>
      _EmojiSubmissionUploadScreenState();
}

class _EmojiSubmissionUploadScreenState
    extends _EmojiSubmissionState<EmojiSubmissionUploadScreen> {
  List<EmojiPackInstallation>? _packs;
  EmojiPackInstallation? _selected;
  final _name = TextEditingController(), _description = TextEditingController();
  bool _rights = false, _uploading = false;
  double? _progress;
  String? _error;
  @override
  void initState() {
    super.initState();
    if (current) unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final packs = await widget.store.load();
      if (current) {
        setState(() => _packs = packs
            .where((pack) =>
                pack.trustLevel == EmojiPackTrustLevel.localUntrusted &&
                !pack.isCatalogPack &&
                pack.status == EmojiPackInstallStatus.installed)
            .toList());
      }
    } catch (error) {
      if (current) setState(() => _error = '读取本机表情包失败，请重试。');
    }
  }

  Future<void> _submit() async {
    if (!current ||
        _uploading ||
        !_rights ||
        _selected == null ||
        _name.text.trim().isEmpty) {
      return;
    }
    final request = nextRequest();
    setState(() {
      _uploading = true;
      _progress = null;
      _error = null;
    });
    try {
      await repository!.submit(
          pack: _selected!,
          store: widget.store,
          name: _name.text,
          description: _description.text,
          session: session!,
          token: request,
          onProgress: (sent, total) {
            if (current && !request.isCancelled) {
              setState(() => _progress = total > 0 ? sent / total : null);
            }
          });
      if (mounted && current && !request.isCancelled) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('已提交，审核结果可在我的投稿查看')));
        Navigator.of(context).pop();
      }
    } catch (error) {
      if (current && !request.isCancelled) {
        setState(() => _error = failureMessage(error));
      }
    } finally {
      if (current && !request.isCancelled) setState(() => _uploading = false);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => EmojiPageScaffold(
      title: '上传表情包',
      formLayout: true,
      body: !current
          ? permissionState
          : ListView(padding: const EdgeInsets.all(AppSpacing.lg), children: [
              const EmojiSectionHeader(
                  title: '选择本机表情包',
                  detail: '每次最多 100 张、合计 49 MB，单张不超过 10 MB；最多 5 份待审核。'),
              if (_packs == null && _error == null)
                const LinearProgressIndicator(),
              if (_packs?.isEmpty == true)
                const EmojiStateView(
                    title: '还没有可投稿的表情包', detail: '返回表情管理，从相册或文件导入后再来分享。'),
              for (final pack in _packs ?? <EmojiPackInstallation>[])
                ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: EmojiCover(
                        image: pack.manifest.assets.isEmpty
                            ? null
                            : FileImage(File(
                                '${widget.store.versionDirectory(pack.packId, pack.version).path}/${pack.manifest.assets.first.path}'))),
                    title: Text(pack.name),
                    subtitle: Text(
                        '${pack.manifest.assets.length} 个 · ${emojiBytesLabel(pack.totalSize)}'),
                    selected: _selected?.packId == pack.packId,
                    trailing: Icon(_selected?.packId == pack.packId
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off),
                    onTap: _uploading
                        ? null
                        : () => setState(() {
                              _selected = pack;
                              _name.text =
                                  pack.name.characters.take(40).toString();
                            })),
              if (_selected != null) ...[
                const SizedBox(height: AppSpacing.lg),
                TextField(
                    controller: _name,
                    enabled: !_uploading,
                    maxLength: 40,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                        labelText: '公开名称', border: OutlineInputBorder())),
                const SizedBox(height: AppSpacing.md),
                TextField(
                    controller: _description,
                    enabled: !_uploading,
                    maxLength: 300,
                    minLines: 2,
                    maxLines: 4,
                    decoration: const InputDecoration(
                        labelText: '简介（选填）',
                        hintText: '介绍内容、作者或授权来源',
                        border: OutlineInputBorder())),
                CheckboxListTile(
                    value: _rights,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    onChanged: _uploading
                        ? null
                        : (value) => setState(() => _rights = value == true),
                    title: const Text('我有权公开分享这些表情'),
                    subtitle:
                        const Text('内容不含他人隐私、违规信息或未经授权的作品；审核通过后所有用户可下载。')),
              ],
              if (_error != null)
                EmojiInlineError(
                    message: _error!,
                    onRetry: _uploading
                        ? null
                        : _packs == null
                            ? _load
                            : _submit),
              if (_uploading)
                Semantics(
                    liveRegion: true,
                    child: Column(children: [
                      LinearProgressIndicator(value: _progress),
                      const SizedBox(height: AppSpacing.sm),
                      Text(_progress == 1 ? '图片已传输，正在提交审核…' : '正在上传，请稍候…'),
                    ])),
            ]),
      bottomNavigationBar: !current
          ? null
          : SafeArea(
              top: false,
              child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  child: FilledButton(
                      onPressed: _uploading ||
                              !_rights ||
                              _selected == null ||
                              _name.text.trim().isEmpty
                          ? null
                          : _submit,
                      style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(48)),
                      child: Text(_uploading ? '提交中…' : '提交审核')))));
}

class _EmojiReviewDialog extends StatefulWidget {
  const _EmojiReviewDialog({required this.action});
  final String action;
  @override
  State<_EmojiReviewDialog> createState() => _EmojiReviewDialogState();
}

class _EmojiReviewDialogState extends State<_EmojiReviewDialog> {
  final _reason = TextEditingController();
  final _form = GlobalKey<FormState>();
  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final action = widget.action;
    final label = switch (action) {
      'approve' => '通过并上架',
      'reject' => '驳回',
      'unpublish' => '下架',
      _ => '撤回投稿'
    };
    return AppAlertDialog(
        title: Text('$label？'),
        content: SingleChildScrollView(
            child: Form(
                key: _form,
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(action == 'approve'
                          ? '请确认已查看全部表情，内容符合公开分享要求。'
                          : action == 'withdraw'
                              ? '撤回后停止公开下载并删除服务端图片，已安装副本和历史消息仍会保留。'
                              : '处理原因会展示给投稿人。'),
                      if (action == 'reject' || action == 'unpublish') ...[
                        const SizedBox(height: AppSpacing.md),
                        TextFormField(
                            controller: _reason,
                            maxLength: 300,
                            minLines: 2,
                            maxLines: 4,
                            decoration: const InputDecoration(
                                labelText: '原因（必填）',
                                border: OutlineInputBorder()),
                            validator: (value) =>
                                value?.trim().isNotEmpty == true
                                    ? null
                                    : '请填写原因，帮助投稿人改进'),
                      ],
                    ]))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
              style: FilledButton.styleFrom(
                  textStyle: Theme.of(context).textTheme.labelLarge),
              onPressed: () {
                if (_form.currentState!.validate()) {
                  Navigator.pop(context, _reason.text.trim());
                }
              },
              child: Text(label)),
        ]);
  }
}

class EmojiSubmissionDetailScreen extends StatefulWidget {
  const EmojiSubmissionDetailScreen(
      {super.key, required this.id, this.admin = false});
  final String id;
  final bool admin;
  @override
  State<EmojiSubmissionDetailScreen> createState() =>
      _EmojiSubmissionDetailScreenState();
}

class _EmojiSubmissionDetailScreenState
    extends _EmojiSubmissionState<EmojiSubmissionDetailScreen> {
  @override
  bool get requireAdmin => widget.admin;
  EmojiSubmission? _item;
  String? _error;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    if (current) unawaited(_load());
  }

  Future<void> _load() async {
    if (!current) return;
    final request = nextRequest();
    setState(() {
      _item = null;
      _error = null;
    });
    try {
      final item = await repository!.detail(widget.id,
          session: session!, token: request, admin: widget.admin);
      if (current && !request.isCancelled) setState(() => _item = item);
    } catch (error) {
      if (current && !request.isCancelled) {
        setState(() => _error = failureMessage(error));
      }
    }
  }

  Future<void> _act(String action) async {
    if (!current || _busy || _item == null) return;
    final reasonText = await showAppDialog<String>(
        context: context,
        builder: (context) => SecuritySessionGuard(
            auth: auth!,
            session: session!,
            requireAdmin: widget.admin,
            child: _EmojiReviewDialog(action: action)));
    if (reasonText == null || !current) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final request = nextRequest();
    try {
      if (action == 'withdraw') {
        await repository!
            .withdraw(widget.id, session: session!, token: request);
      } else {
        await repository!.review(widget.id, action, reasonText,
            session: session!, token: request);
      }
      if (current && !request.isCancelled) await _load();
    } catch (error) {
      if (mounted && current && !request.isCancelled) {
        setState(() => _error = failureMessage(error));
        if (error is DioException && error.response?.statusCode == 409) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(failureMessage(error))));
          await _load();
        }
      }
    } finally {
      if (current) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = _item;
    final canReview = current && widget.admin && item?.userId != auth?.user?.id;
    return EmojiPageScaffold(
        title: '投稿详情',
        body: !current
            ? permissionState
            : ListView(padding: const EdgeInsets.all(AppSpacing.lg), children: [
                if (_error != null)
                  EmojiInlineError(
                      message: _error!, onRetry: _busy ? null : _load),
                if (item == null && _error == null)
                  const LinearProgressIndicator(),
                if (item != null) ...[
                  EmojiSectionHeader(
                      title: item.name,
                      detail:
                          '${emojiSubmissionStatus(item.status)} · ${item.assetCount} 个 · ${emojiBytesLabel(item.totalSize)}'),
                  if (widget.admin) Text('投稿人 ID：${item.userId}'),
                  if (item.description.isNotEmpty) Text(item.description),
                  if (item.reviewReason.isNotEmpty)
                    Padding(
                        padding:
                            const EdgeInsets.symmetric(vertical: AppSpacing.md),
                        child: Text('处理原因：${item.reviewReason}')),
                  if (item.status == 'withdrawn')
                    const EmojiStateView(title: '投稿已撤回，服务端图片已删除')
                  else ...[
                    const EmojiSectionHeader(title: '全部表情', detail: '点击查看大图'),
                    EmojiPreviewGrid(
                        shrinkWrap: true,
                        items: [
                          for (final asset in item.assets)
                            EmojiPreviewItem(
                                id: asset.id,
                                name: asset.name,
                                animated: asset.animated,
                                image: EmojiSubmissionImage(
                                    dio: auth!.dio,
                                    session: session!,
                                    token: token,
                                    url: repository!.assetUrl(item.id, asset.id,
                                        admin: widget.admin)))
                        ],
                        onSelected: (preview) => showEmojiPreview(
                            context, preview,
                            session: auth, isCurrent: () => current)),
                  ],
                  if (widget.admin && item.userId == auth?.user?.id)
                    const Padding(
                        padding: EdgeInsets.only(top: AppSpacing.lg),
                        child: Text('自己的投稿需要由其他管理员审核。')),
                ],
              ]),
        bottomNavigationBar: !current || item == null
            ? null
            : SafeArea(
                top: false,
                child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.lg),
                    child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (_busy) const LinearProgressIndicator(),
                          if (canReview && item.status == 'pending') ...[
                            FilledButton(
                                onPressed: _busy ? null : () => _act('approve'),
                                child: const Text('通过并上架')),
                            OutlinedButton(
                                onPressed: _busy ? null : () => _act('reject'),
                                child: const Text('驳回并说明原因')),
                          ],
                          if (canReview && item.status == 'published')
                            OutlinedButton(
                                onPressed:
                                    _busy ? null : () => _act('unpublish'),
                                child: const Text('下架表情包')),
                          if (!widget.admin && item.status != 'withdrawn')
                            OutlinedButton(
                                onPressed:
                                    _busy ? null : () => _act('withdraw'),
                                child: const Text('撤回投稿')),
                        ]))));
  }
}

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../../theme/app_spacing.dart';
import '../../../widgets/app_choice_chip.dart';
import '../../../widgets/app_dialog.dart';
import '../../../widgets/security_session_guard.dart';
import '../data/emoji_pack_local_store.dart';
import '../data/emoji_submission_repository.dart';
import 'emoji_ui.dart';
import 'emoji_session_state.dart';
import 'emoji_creation_editor_screen.dart';
import 'emoji_submission_image.dart';

class EmojiSubmissionsScreen extends StatefulWidget {
  const EmojiSubmissionsScreen({super.key, this.store, this.admin = false});
  final EmojiPackLocalStore? store;
  final bool admin;
  @override
  State<EmojiSubmissionsScreen> createState() => _EmojiSubmissionsScreenState();
}

class _EmojiSubmissionsScreenState
    extends EmojiSessionState<EmojiSubmissionsScreen> {
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
        builder: (_) => SecuritySessionGuard(
            auth: auth!,
            session: session!,
            requireAdmin: widget.admin,
            child: EmojiSubmissionDetailScreen(
                id: item.id, admin: widget.admin, store: widget.store))));
    if (current) await _load();
  }

  Future<void> _upload() async {
    if (!current || widget.store == null) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => SecuritySessionGuard(
            auth: auth!,
            session: session!,
            child: EmojiSubmissionUploadScreen(store: widget.store!))));
    if (current) await _load();
  }

  @override
  Widget build(BuildContext context) => EmojiPageScaffold(
      title: widget.admin ? '表情包审核' : '我的作品',
      actions: [
        if (!widget.admin && current && widget.store != null)
          TextButton(onPressed: _upload, child: const Text('制作'))
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
                            'unpublished',
                            'superseded'
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
                              '${emojiSubmissionStatus(item.status)} · v${item.version} · ${item.assetCount} 个表情'
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

class EmojiSubmissionUploadScreen extends StatelessWidget {
  const EmojiSubmissionUploadScreen(
      {super.key, required this.store, this.revisionOf});
  final EmojiPackLocalStore store;
  final String? revisionOf;
  @override
  Widget build(BuildContext context) =>
      EmojiCreationEditorScreen(store: store, revisionOf: revisionOf);
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
      {super.key, required this.id, this.admin = false, this.store});
  final String id;
  final bool admin;
  final EmojiPackLocalStore? store;
  @override
  State<EmojiSubmissionDetailScreen> createState() =>
      _EmojiSubmissionDetailScreenState();
}

class _EmojiSubmissionDetailScreenState
    extends EmojiSessionState<EmojiSubmissionDetailScreen> {
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
                  Text(
                      '版本 ${item.version}${item.tags.isEmpty ? '' : ' · ${item.tags.join(' · ')}'}'),
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
                                        admin: widget.admin, thumbnail: true)),
                                previewImage: EmojiSubmissionImage(
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
                          if (!widget.admin &&
                              widget.store != null &&
                              !['pending', 'withdrawn', 'superseded']
                                  .contains(item.status))
                            OutlinedButton(
                                onPressed: _busy
                                    ? null
                                    : () async {
                                        if (!current) return;
                                        await Navigator.of(context).push(
                                            MaterialPageRoute<void>(
                                                builder: (_) => SecuritySessionGuard(
                                                    auth: auth!,
                                                    session: session!,
                                                    child:
                                                        EmojiSubmissionUploadScreen(
                                                            store:
                                                                widget.store!,
                                                            revisionOf: item
                                                                .catalogId))));
                                        if (current) await _load();
                                      },
                                child: const Text('制作新版本')),
                        ]))));
  }
}

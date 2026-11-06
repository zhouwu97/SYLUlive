import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import '../../../theme/app_spacing.dart';
import '../../../widgets/app_choice_chip.dart';
import '../../../widgets/app_dialog.dart';
import '../../../widgets/security_session_guard.dart';
import '../data/emoji_pack_local_store.dart';
import '../data/emoji_pack_runtime.dart';
import '../domain/emoji_creator.dart';
import 'emoji_session_state.dart';
import 'emoji_submissions_screen.dart';
import 'emoji_ui.dart';

class EmojiCreatorScreen extends StatefulWidget {
  const EmojiCreatorScreen({super.key, this.store});
  final EmojiPackLocalStore? store;
  @override
  State<EmojiCreatorScreen> createState() => _EmojiCreatorScreenState();
}

class _EmojiCreatorScreenState extends EmojiSessionState<EmojiCreatorScreen> {
  EmojiCreator? _creator;
  EmojiPackLocalStore? _store;
  final _description = TextEditingController();
  bool _rights = false, _busy = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    if (current) unawaited(_load());
  }

  Future<void> _load() async {
    if (!current) return;
    final request = nextRequest();
    setState(() {
      _error = null;
      _creator = null;
    });
    try {
      final creator =
          await repository!.creator(session: session!, token: request);
      final store = widget.store ??
          await EmojiPackRuntime.forAccount('${session!.accountId}');
      if (!current || request.isCancelled) return;
      setState(() {
        _creator = creator;
        _store = store;
        if (_description.text.isEmpty) _description.text = creator.description;
      });
    } catch (error) {
      if (current && !request.isCancelled) {
        setState(() => _error = failureMessage(error));
      }
    }
  }

  Future<void> _apply() async {
    if (!current ||
        _busy ||
        !_rights ||
        _description.text.trim().isEmpty ||
        _creator == null) {
      return;
    }
    final request = nextRequest();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final creator = await repository!.applyCreator(
          _description.text, _creator!.version,
          session: session!, token: request);
      if (current && !request.isCancelled) setState(() => _creator = creator);
    } catch (error) {
      if (current && !request.isCancelled) {
        setState(() => _error = failureMessage(error));
        if (error is DioException && error.response?.statusCode == 409) {
          await _load();
        }
      }
    } finally {
      if (current) setState(() => _busy = false);
    }
  }

  Future<void> _open(bool edit) async {
    if (!current || _store == null) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => edit
            ? EmojiSubmissionUploadScreen(store: _store!)
            : EmojiSubmissionsScreen(store: _store)));
    if (current) await _load();
  }

  @override
  void dispose() {
    _description.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final creator = _creator;
    final apply = creator != null &&
        ['none', 'rejected', 'suspended'].contains(creator.status);
    return EmojiPageScaffold(
        title: '创作中心',
        formLayout: true,
        body: !current
            ? permissionState
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(AppSpacing.lg),
                    children: [
                      const EmojiSectionHeader(
                          title: '把你的表情分享给校园',
                          detail: '本机导入自用自由开放；申请创作者权限后可制作作品，逐包审核通过后免费上架。'),
                      if (_error != null)
                        EmojiInlineError(
                            message: _error!, onRetry: _busy ? null : _load),
                      if (creator == null && _error == null)
                        const LinearProgressIndicator(),
                      if (creator != null) ...[
                        ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(creator.active
                                ? Icons.verified_outlined
                                : creator.status == 'pending'
                                    ? Icons.hourglass_top
                                    : Icons.info_outline),
                            title: Text(emojiCreatorStatus(creator.status)),
                            subtitle: creator.reviewReason.isEmpty
                                ? null
                                : Text('处理原因：${creator.reviewReason}')),
                        if (creator.active) ...[
                          FilledButton.icon(
                              onPressed: () => _open(true),
                              icon: const Icon(
                                  Icons.add_photo_alternate_outlined),
                              label: const Text('制作表情包')),
                          const SizedBox(height: AppSpacing.sm),
                          OutlinedButton.icon(
                              onPressed: () => _open(false),
                              icon: const Icon(Icons.collections_outlined),
                              label: const Text('我的作品')),
                          const EmojiSectionHeader(
                              title: '准备图片和对应文字',
                              detail:
                                  '从本机包复制素材，编辑每张文字、封面和面板图标。系统自动生成静态缩略图和下载资源。'),
                          const Text('作品修改作为新版本重新审核。审核期间，已上架版本继续提供下载。'),
                        ] else if (creator.status == 'pending') ...[
                          const Text('申请已提交，请等待管理员处理。审核结果会在这里显示。'),
                          const SizedBox(height: AppSpacing.md),
                          const Text('等待期间仍可导入自用、整理个人标签和免费下载商城表情。'),
                        ],
                        if (apply) ...[
                          if (creator.status == 'suspended')
                            const Text('暂停期间无法提交新作品，已有自用表情和本机草稿保留。可补充材料申请恢复。'),
                          TextField(
                              controller: _description,
                              enabled: !_busy,
                              maxLength: 300,
                              minLines: 3,
                              maxLines: 6,
                              onChanged: (_) => setState(() {}),
                              decoration: const InputDecoration(
                                  labelText: '创作介绍',
                                  hintText: '介绍准备制作的内容、素材来源或已有作品',
                                  border: OutlineInputBorder())),
                          CheckboxListTile(
                              contentPadding: EdgeInsets.zero,
                              controlAffinity: ListTileControlAffinity.leading,
                              value: _rights,
                              onChanged: _busy
                                  ? null
                                  : (value) =>
                                      setState(() => _rights = value == true),
                              title: const Text('我理解公开分享规则'),
                              subtitle:
                                  const Text('只提交自己有权分享的图片、封面和文字，作品免费提供下载。')),
                          if (_busy) const LinearProgressIndicator(),
                          FilledButton(
                              onPressed: _busy ||
                                      !_rights ||
                                      _description.text.trim().isEmpty
                                  ? null
                                  : _apply,
                              child: Text(creator.status == 'suspended'
                                  ? '补充材料，申请恢复'
                                  : creator.status == 'rejected'
                                      ? '重新提交申请'
                                      : '提交创作者申请')),
                        ],
                        if (!creator.active)
                          TextButton(
                              onPressed:
                                  _store == null ? null : () => _open(false),
                              child: const Text('查看已有作品与审核记录')),
                      ],
                    ])));
  }
}

class EmojiCreatorReviewScreen extends StatefulWidget {
  const EmojiCreatorReviewScreen({super.key});
  @override
  State<EmojiCreatorReviewScreen> createState() => _EmojiCreatorReviewState();
}

class _EmojiCreatorReviewState
    extends EmojiSessionState<EmojiCreatorReviewScreen> {
  @override
  bool get requireAdmin => true;
  List<EmojiCreator>? _items;
  String _status = 'pending';
  String? _error;
  int _page = 0, _total = 0;
  bool _loading = false, _acting = false, _retryMore = false;
  @override
  void initState() {
    super.initState();
    if (current) unawaited(_load());
  }

  Future<void> _load({bool more = false}) async {
    if (!current || more && _loading) return;
    final request = nextRequest();
    setState(() {
      _loading = true;
      _error = null;
      _retryMore = more;
    });
    try {
      final page = more ? _page + 1 : 1;
      final result = await repository!
          .creators(_status, page, session: session!, token: request);
      if (current && !request.isCancelled) {
        setState(() {
          _items = more ? [...?_items, ...result.items] : result.items;
          _total = result.total;
          _page = page;
        });
      }
    } catch (error) {
      if (current && !request.isCancelled) {
        setState(() => _error = failureMessage(error));
      }
    } finally {
      if (current && !request.isCancelled) setState(() => _loading = false);
    }
  }

  Future<void> _review(EmojiCreator creator, String action) async {
    if (!current || _acting) return;
    final reasonText = await showDialog<String>(
        context: context,
        builder: (_) => SecuritySessionGuard(
            auth: auth!,
            session: session!,
            requireAdmin: true,
            child:
                _EmojiCreatorDecisionDialog(creator: creator, action: action)));
    if (reasonText == null || !current) return;
    final request = nextRequest();
    setState(() {
      _acting = true;
      _error = null;
    });
    try {
      await repository!.reviewCreator(creator, action, reasonText,
          session: session!, token: request);
      if (current && !request.isCancelled) await _load();
    } catch (error) {
      if (current && !request.isCancelled) {
        setState(() => _error = failureMessage(error));
        if (error is DioException && error.response?.statusCode == 409) {
          await _load();
        }
      }
    } finally {
      if (current) setState(() => _acting = false);
    }
  }

  @override
  Widget build(BuildContext context) => EmojiPageScaffold(
      title: '表情创作者审核',
      body: !current
          ? permissionState
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  children: [
                    const EmojiSectionHeader(
                        title: '申请与创作权限',
                        detail: '申请权限与作品上架分别审核。暂停创作权限不会删除用户的自用表情。'),
                    Wrap(
                        spacing: AppSpacing.sm,
                        runSpacing: AppSpacing.xs,
                        children: [
                          for (final status in [
                            'pending',
                            'active',
                            'rejected',
                            'suspended'
                          ])
                            AppChoiceChip(
                                label: Text(emojiCreatorStatus(status)),
                                selected: _status == status,
                                onSelected: _acting
                                    ? null
                                    : (_) {
                                        setState(() {
                                          _status = status;
                                          _items = null;
                                          _page = 0;
                                        });
                                        unawaited(_load());
                                      })
                        ]),
                    if (_loading || _acting) const LinearProgressIndicator(),
                    if (_error != null)
                      EmojiInlineError(
                          message: _error!,
                          onRetry:
                              _acting ? null : () => _load(more: _retryMore)),
                    if (_items?.isEmpty == true)
                      const EmojiStateView(title: '暂无对应申请'),
                    for (final creator in _items ?? <EmojiCreator>[])
                      Padding(
                          padding: const EdgeInsets.symmetric(
                              vertical: AppSpacing.md),
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text('申请人 ID：${creator.userId}',
                                    style:
                                        Theme.of(context).textTheme.titleSmall),
                                Text(creator.description),
                                if (creator.reviewReason.isNotEmpty)
                                  Text('处理原因：${creator.reviewReason}'),
                                if (creator.userId == auth?.user?.id)
                                  const Text('自己的申请需要由其他管理员处理。')
                                else if (creator.status == 'pending')
                                  Wrap(spacing: AppSpacing.sm, children: [
                                    FilledButton(
                                        onPressed: _acting
                                            ? null
                                            : () => _review(creator, 'approve'),
                                        child: const Text('开通权限')),
                                    OutlinedButton(
                                        onPressed: _acting
                                            ? null
                                            : () => _review(creator, 'reject'),
                                        child: const Text('驳回并说明原因'))
                                  ])
                                else if (creator.status == 'active')
                                  OutlinedButton(
                                      onPressed: _acting
                                          ? null
                                          : () => _review(creator, 'suspend'),
                                      child: const Text('暂停并说明原因')),
                              ])),
                    if (_items != null && _items!.length < _total)
                      TextButton(
                          onPressed: _loading || _acting
                              ? null
                              : () => _load(more: true),
                          child: const Text('加载更多')),
                  ])));
}

class _EmojiCreatorDecisionDialog extends StatefulWidget {
  const _EmojiCreatorDecisionDialog(
      {required this.creator, required this.action});
  final EmojiCreator creator;
  final String action;
  @override
  State<_EmojiCreatorDecisionDialog> createState() =>
      _EmojiCreatorDecisionDialogState();
}

class _EmojiCreatorDecisionDialogState
    extends State<_EmojiCreatorDecisionDialog> {
  final _reason = TextEditingController();
  final _form = GlobalKey<FormState>();
  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.action == 'approve'
        ? '开通创作者权限'
        : widget.action == 'reject'
            ? '驳回申请'
            : '暂停创作者权限';
    return AppAlertDialog(
        title: Text('$label？'),
        content: SingleChildScrollView(
            child: Form(
                key: _form,
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('申请人 ID：${widget.creator.userId}'),
                      Text(widget.creator.description),
                      if (widget.action == 'approve')
                        const Text('开通后可提交作品，每个表情包仍需单独审核。')
                      else
                        TextFormField(
                            controller: _reason,
                            maxLength: 300,
                            minLines: 2,
                            maxLines: 4,
                            decoration:
                                const InputDecoration(labelText: '原因（必填）'),
                            validator: (value) =>
                                value?.trim().isNotEmpty == true
                                    ? null
                                    : '请填写处理原因'),
                    ]))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
              onPressed: () {
                if (_form.currentState!.validate()) {
                  Navigator.pop(context, _reason.text.trim());
                }
              },
              child: Text(label))
        ]);
  }
}

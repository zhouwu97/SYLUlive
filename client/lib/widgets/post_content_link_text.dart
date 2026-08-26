import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../platform/contracts/external_navigator.dart';
import '../platform/contracts/text_boundary_resolver.dart';
import '../theme/app_colors.dart';
import '../utils/app_feedback.dart';
import '../utils/smart_text_selection.dart';

export '../utils/smart_text_selection.dart'
    show
        PostContentLink,
        SmartSelectionKind,
        SmartSelectionResolution,
        SmartSelectionToken,
        SmartTextSelectionResolver,
        extractPostContentLinks,
        parsePostContentUri;

/// 帖子/评论正文中的可选文本组件。
///
/// [selectable] 为 true 时只使用一套 [SelectableText.rich] 选择系统，负责
/// URL 高亮、原生手柄/放大镜、智能选词和应用自有菜单；为 false 时保持信息流
/// 卡片原有的普通富文本展示与整帖长按行为。
class PostContentLinkText extends StatefulWidget {
  final String text;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow overflow;
  final TextAlign textAlign;
  final bool softWrap;
  final ExternalNavigator? navigator;
  final bool selectable;
  final int? leadingTextEnd;
  final TextStyle? leadingTextStyle;
  final TextBoundaryResolver? textBoundaryResolver;
  final ValueChanged<TextSelection>? onSelectionChanged;
  final Future<void> Function(String text)? onShare;
  final VoidCallback? onPlainTextTap;

  const PostContentLinkText({
    super.key,
    required this.text,
    this.style,
    this.maxLines,
    this.overflow = TextOverflow.clip,
    this.textAlign = TextAlign.start,
    this.softWrap = true,
    this.navigator,
    this.selectable = false,
    this.leadingTextEnd,
    this.leadingTextStyle,
    this.textBoundaryResolver,
    this.onSelectionChanged,
    this.onShare,
    this.onPlainTextTap,
  });

  @override
  State<PostContentLinkText> createState() => _PostContentLinkTextState();
}

class _SmartExpansionRequest {
  final int id;
  final TextSelection selection;

  const _SmartExpansionRequest({required this.id, required this.selection});
}

class _PostContentLinkTextState extends State<PostContentLinkText> {
  final _recognizers = <TapGestureRecognizer>[];
  List<TextSpan> _spans = const [];
  EditableTextState? _editableTextState;
  _SmartExpansionRequest? _pendingSmartExpansion;
  int? _scheduledSmartExpansionId;
  int _smartExpansionId = 0;
  bool _applyingSmartSelection = false;

  @override
  void initState() {
    super.initState();
    _rebuildSpans();
  }

  @override
  void didUpdateWidget(covariant PostContentLinkText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text ||
        oldWidget.style != widget.style ||
        oldWidget.leadingTextEnd != widget.leadingTextEnd ||
        oldWidget.leadingTextStyle != widget.leadingTextStyle ||
        oldWidget.onPlainTextTap != widget.onPlainTextTap) {
      _rebuildSpans();
      _invalidateSmartSelection();
    }
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _rebuildSpans() {
    _disposeRecognizers();
    final links = extractPostContentLinks(widget.text);
    final spans = <TextSpan>[];
    var cursor = 0;
    final linkStyle = (widget.style ?? const TextStyle()).copyWith(
      color: AppColors.brandPrimary,
      decoration: TextDecoration.underline,
      decorationColor: AppColors.brandPrimary,
    );

    void addPlainSpan(int start, int end) {
      if (start >= end) return;
      final leadingEnd =
          (widget.leadingTextEnd ?? 0).clamp(0, widget.text.length);
      if (start < leadingEnd) {
        final firstEnd = end < leadingEnd ? end : leadingEnd;
        final recognizer = _plainTextRecognizer();
        spans.add(
          TextSpan(
            text: widget.text.substring(start, firstEnd),
            style: widget.leadingTextStyle,
            recognizer: recognizer,
          ),
        );
        if (firstEnd >= end) return;
        start = firstEnd;
      }
      spans.add(
        TextSpan(
          text: widget.text.substring(start, end),
          recognizer: _plainTextRecognizer(),
        ),
      );
    }

    for (final link in links) {
      if (link.start > cursor) addPlainSpan(cursor, link.start);
      final recognizer = TapGestureRecognizer()
        ..onTap = () => _confirmOpen(link.uri);
      _recognizers.add(recognizer);
      spans.add(
        TextSpan(
          text: link.text,
          style: linkStyle,
          recognizer: recognizer,
        ),
      );
      cursor = link.end;
    }
    if (cursor < widget.text.length) {
      addPlainSpan(cursor, widget.text.length);
    }
    if (spans.isEmpty) spans.add(TextSpan(text: widget.text));
    _spans = spans;
  }

  TapGestureRecognizer? _plainTextRecognizer() {
    final onTap = widget.onPlainTextTap;
    if (onTap == null) return null;
    final recognizer = TapGestureRecognizer()..onTap = onTap;
    _recognizers.add(recognizer);
    return recognizer;
  }

  void _disposeRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  Future<void> _confirmOpen(Uri uri) async {
    final shouldOpen = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('打开网页？'),
            content: Text(
              '确定要跳转到以下网址吗？\n${uri.toString()}',
              maxLines: 5,
              overflow: TextOverflow.ellipsis,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('打开'),
              ),
            ],
          ),
        ) ??
        false;
    if (!mounted || !shouldOpen) return;

    final opened =
        await (widget.navigator ?? ExternalNavigator.current()).open(uri);
    if (!mounted || opened) return;
    AppFeedback.info('无法打开该网址', context: context);
  }

  void _invalidateSmartSelection() {
    _smartExpansionId++;
    _pendingSmartExpansion = null;
  }

  void _handleSelectionChanged(
    TextSelection selection,
    SelectionChangedCause? cause,
  ) {
    if (!_applyingSmartSelection) {
      if (cause == SelectionChangedCause.longPress ||
          cause == SelectionChangedCause.doubleTap) {
        final request = _SmartExpansionRequest(
          id: ++_smartExpansionId,
          selection: selection,
        );
        _pendingSmartExpansion = request;
        final editableTextState = _editableTextState;
        if (editableTextState != null) {
          _applySmartExpansion(request, editableTextState);
        } else {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || _pendingSmartExpansion?.id != request.id) return;
            final state = _editableTextState;
            if (state != null) _applySmartExpansion(request, state);
          });
        }
      } else {
        // drag / toolbar / keyboard / tap 都会把本次智能扩展上下文作废，
        // 防止用户拖动手柄后异步 ICU 结果把选区弹回去。
        _invalidateSmartSelection();
      }
    }
    widget.onSelectionChanged?.call(selection);
  }

  void _applySmartExpansion(
    _SmartExpansionRequest request,
    EditableTextState editableTextState,
  ) {
    if (!mounted || !editableTextState.mounted) return;
    if (_pendingSmartExpansion?.id != request.id) return;
    final value = editableTextState.textEditingValue;
    if (value.text != widget.text || value.selection != request.selection) {
      _pendingSmartExpansion = null;
      return;
    }
    _pendingSmartExpansion = null;

    final syncResolution = SmartTextSelectionResolver.resolveSelection(
      widget.text,
      request.selection,
    );
    _updateEditableSelection(editableTextState, syncResolution.selection);

    final probe = _probeOffset(request.selection, widget.text.length);
    if (!SmartTextSelectionResolver.isCjkAt(widget.text, probe)) return;

    final resolver =
        widget.textBoundaryResolver ?? SmartWordBoundaryPlatform.resolver;
    final requestId = request.id;
    final expectedSelection = syncResolution.selection;
    unawaited(
      resolver
          .resolveWordBoundary(text: widget.text, offset: probe)
          .then((boundary) {
        if (boundary == null ||
            !mounted ||
            !editableTextState.mounted ||
            requestId != _smartExpansionId ||
            editableTextState.textEditingValue.text != widget.text ||
            editableTextState.textEditingValue.selection != expectedSelection) {
          return;
        }
        final platformResolution = SmartTextSelectionResolver.resolveSelection(
          widget.text,
          request.selection,
          cjkWordBoundary: boundary,
        );
        if (platformResolution.kind != SmartSelectionKind.cjkWord) return;
        _updateEditableSelection(
            editableTextState, platformResolution.selection);
      }).catchError((_) {}),
    );
  }

  void _scheduleSmartExpansion(
    _SmartExpansionRequest request,
    EditableTextState editableTextState,
  ) {
    if (_scheduledSmartExpansionId == request.id) return;
    _scheduledSmartExpansionId = request.id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scheduledSmartExpansionId == request.id) {
        _scheduledSmartExpansionId = null;
      }
      if (!mounted || _pendingSmartExpansion?.id != request.id) return;
      _applySmartExpansion(request, editableTextState);
    });
  }

  void _updateEditableSelection(
    EditableTextState editableTextState,
    TextSelection selection,
  ) {
    if (editableTextState.textEditingValue.selection == selection) return;
    _applyingSmartSelection = true;
    try {
      editableTextState.userUpdateTextEditingValue(
        editableTextState.textEditingValue.copyWith(selection: selection),
        null,
      );
    } finally {
      _applyingSmartSelection = false;
    }
  }

  int _probeOffset(TextSelection selection, int textLength) {
    final raw = selection.extentOffset;
    if (raw >= 0 && raw < textLength) return raw;
    if (selection.baseOffset >= 0 && selection.baseOffset < textLength) {
      return selection.baseOffset;
    }
    return textLength == 0 ? 0 : textLength - 1;
  }

  Widget _buildContextMenu(
    BuildContext context,
    EditableTextState editableTextState,
  ) {
    _editableTextState = editableTextState;
    final pending = _pendingSmartExpansion;
    if (pending != null) {
      // Context menu builder 运行在 overlay 的 build 阶段，不能在这里直接
      // 修改 EditableText 的 selection；延迟到当前帧结束，避免 setState
      // during build，同时保留菜单首次展示时的正确动作分类。
      _scheduleSmartExpansion(pending, editableTextState);
    }

    final rawSelection = editableTextState.textEditingValue.selection;
    final selection = pending == null
        ? rawSelection
        : SmartTextSelectionResolver.resolveSelection(
            widget.text,
            pending.selection,
          ).selection;
    final selected =
        selection.textInside(editableTextState.textEditingValue.text);
    if (selection.isCollapsed || selected.isEmpty) {
      return const SizedBox.shrink();
    }

    final isUrl = SmartTextSelectionResolver.isUrl(selected);
    final items = <ContextMenuButtonItem>[
      ContextMenuButtonItem(
        type: ContextMenuButtonType.copy,
        label: '复制',
        onPressed: () {
          editableTextState.copySelection(SelectionChangedCause.toolbar);
        },
      ),
      ContextMenuButtonItem(
        type: ContextMenuButtonType.custom,
        label: isUrl ? '打开链接' : '搜索',
        onPressed: () {
          editableTextState.hideToolbar();
          if (isUrl) {
            final uri = parsePostContentUri(selected);
            if (uri != null) unawaited(_confirmOpen(uri));
          } else {
            unawaited(_searchSelection(selected));
          }
        },
      ),
      ContextMenuButtonItem(
        type: ContextMenuButtonType.custom,
        label: '分享',
        onPressed: () {
          editableTextState.hideToolbar();
          unawaited(_shareSelection(selected));
        },
      ),
    ];
    if (selection.start != 0 || selection.end != widget.text.length) {
      items.add(
        ContextMenuButtonItem(
          type: ContextMenuButtonType.selectAll,
          label: '全选',
          onPressed: () {
            editableTextState.selectAll(SelectionChangedCause.toolbar);
          },
        ),
      );
    }

    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: editableTextState.contextMenuAnchors,
      buttonItems: items,
    );
  }

  Future<void> _searchSelection(String selected) async {
    final uri = Uri.https(
      'www.baidu.com',
      '/s',
      <String, String>{'wd': selected},
    );
    final opened =
        await (widget.navigator ?? ExternalNavigator.current()).open(uri);
    if (!mounted || opened) return;
    AppFeedback.info('无法打开搜索结果', context: context);
  }

  Future<void> _shareSelection(String selected) async {
    try {
      if (widget.onShare != null) {
        await widget.onShare!(selected);
      } else {
        await Share.share(selected, subject: 'SYLUlive 文本');
      }
    } catch (_) {
      if (mounted) AppFeedback.info('暂时无法分享选中文本', context: context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final textSpan = TextSpan(style: widget.style, children: _spans);
    if (widget.selectable) {
      return SelectableText.rich(
        textSpan,
        maxLines: widget.maxLines,
        textAlign: widget.textAlign,
        onSelectionChanged: _handleSelectionChanged,
        contextMenuBuilder: _buildContextMenu,
        semanticsLabel: widget.text,
      );
    }
    return Text.rich(
      textSpan,
      maxLines: widget.maxLines,
      overflow: widget.overflow,
      textAlign: widget.textAlign,
      softWrap: widget.softWrap,
    );
  }
}

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../platform/contracts/external_navigator.dart';
import '../theme/app_colors.dart';
import '../utils/app_feedback.dart';

final RegExp _postContentUrlPattern = RegExp(
  r'(?:(?:https?://)|(?:www\.))[^\s<>"\u0000-\u001F，。！？；：、（）【】]+',
  caseSensitive: false,
);

const _urlTrailingPunctuation = '.,!?;:)]}，。！？；：）】、';

class PostContentLink {
  final String text;
  final int start;
  final int end;
  final Uri uri;

  const PostContentLink({
    required this.text,
    required this.start,
    required this.end,
    required this.uri,
  });
}

/// 提取帖子正文中的网页链接。
///
/// 只暴露 http/https 链接；`www.` 链接在实际打开时补充 https 协议。
List<PostContentLink> extractPostContentLinks(String text) {
  final links = <PostContentLink>[];
  for (final match in _postContentUrlPattern.allMatches(text)) {
    final raw = match.group(0);
    if (raw == null || raw.isEmpty) continue;

    final linkText = _trimUrlTrailingPunctuation(raw);
    if (linkText.isEmpty) continue;
    final uri = _parsePostContentUri(linkText);
    if (uri == null) continue;

    links.add(
      PostContentLink(
        text: linkText,
        start: match.start,
        end: match.start + linkText.length,
        uri: uri,
      ),
    );
  }
  return links;
}

String _trimUrlTrailingPunctuation(String value) {
  var end = value.length;
  while (end > 0 && _urlTrailingPunctuation.contains(value[end - 1])) {
    end--;
  }
  return value.substring(0, end);
}

Uri? _parsePostContentUri(String value) {
  final candidate =
      value.toLowerCase().startsWith('www.') ? 'https://$value' : value;
  final uri = Uri.tryParse(candidate);
  if (uri == null || uri.host.isEmpty) return null;
  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') return null;
  return uri;
}

class PostContentLinkText extends StatefulWidget {
  final String text;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow overflow;
  final TextAlign textAlign;
  final bool softWrap;
  final ExternalNavigator? navigator;

  const PostContentLinkText({
    super.key,
    required this.text,
    this.style,
    this.maxLines,
    this.overflow = TextOverflow.clip,
    this.textAlign = TextAlign.start,
    this.softWrap = true,
    this.navigator,
  });

  @override
  State<PostContentLinkText> createState() => _PostContentLinkTextState();
}

class _PostContentLinkTextState extends State<PostContentLinkText> {
  final _recognizers = <TapGestureRecognizer>[];
  List<TextSpan> _spans = const [];

  @override
  void initState() {
    super.initState();
    _rebuildSpans();
  }

  @override
  void didUpdateWidget(covariant PostContentLinkText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text || oldWidget.style != widget.style) {
      _rebuildSpans();
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

    for (final link in links) {
      if (link.start > cursor) {
        spans.add(TextSpan(text: widget.text.substring(cursor, link.start)));
      }
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
      spans.add(TextSpan(text: widget.text.substring(cursor)));
    }
    if (spans.isEmpty) spans.add(TextSpan(text: widget.text));
    _spans = spans;
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

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(style: widget.style, children: _spans),
      maxLines: widget.maxLines,
      overflow: widget.overflow,
      textAlign: widget.textAlign,
      softWrap: widget.softWrap,
    );
  }
}

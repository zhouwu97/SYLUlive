import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:html/dom.dart' as html_dom;
import 'package:html/parser.dart' show parseFragment;

import '../../theme/app_colors.dart';
import '../../theme/app_radius.dart';
import '../../theme/app_spacing.dart';

/// 清洗后校园资讯 HTML 的轻量原生渲染器。
///
/// 服务端负责 HTML 白名单清洗，这里只渲染有限的语义标签，并再次拒绝
/// 危险链接。使用 Flutter 自己的文本、表格和图片组件，不加载原站 CSS/JS。
class CampusArticleHtmlView extends StatefulWidget {
  final String html;
  final String baseUrl;
  final ValueChanged<String>? onOpenLink;
  final ValueChanged<String>? onOpenImage;

  const CampusArticleHtmlView({
    super.key,
    required this.html,
    this.baseUrl = '',
    this.onOpenLink,
    this.onOpenImage,
  });

  @override
  State<CampusArticleHtmlView> createState() => _CampusArticleHtmlViewState();
}

class _CampusArticleHtmlViewState extends State<CampusArticleHtmlView> {
  final _recognizers = <TapGestureRecognizer>[];

  @override
  void didUpdateWidget(covariant CampusArticleHtmlView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.html != widget.html ||
        oldWidget.baseUrl != widget.baseUrl ||
        oldWidget.onOpenLink != widget.onOpenLink) {
      _disposeRecognizers();
    }
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  @override
  Widget build(BuildContext context) {
    _disposeRecognizers();
    final fragment = parseFragment(widget.html);
    final bodyStyle = _bodyStyle(context);
    final content = _buildFlow(
      context,
      fragment.nodes,
      bodyStyle,
    );

    return SelectionArea(child: content);
  }

  TextStyle _bodyStyle(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return (theme.textTheme.bodyLarge ?? const TextStyle()).copyWith(
      height: 1.75,
      color: isDark ? AppColors.textPrimaryDark : AppColors.textPrimaryLight,
    );
  }

  List<Widget> _buildFlowChildren(
    BuildContext context,
    List<html_dom.Node> nodes,
    TextStyle style, {
    TextAlign textAlign = TextAlign.start,
  }) {
    final widgets = <Widget>[];
    final inlineNodes = <html_dom.Node>[];

    void flushInline() {
      if (!_hasVisibleInlineContent(inlineNodes)) {
        inlineNodes.clear();
        return;
      }
      final spans = _buildInlineSpans(context, inlineNodes, style);
      if (spans.isNotEmpty) {
        widgets.add(
          SelectableText.rich(
            TextSpan(style: style, children: spans),
            textAlign: textAlign,
            semanticsLabel: _inlineText(inlineNodes),
          ),
        );
      }
      inlineNodes.clear();
    }

    for (final node in nodes) {
      if (node is html_dom.Text) {
        if (node.data.trim().isNotEmpty || inlineNodes.isNotEmpty) {
          inlineNodes.add(node);
        }
        continue;
      }

      if (node is! html_dom.Element) continue;
      final tag = _tagName(node);
      if (_isInlineTag(tag)) {
        inlineNodes.add(node);
      } else {
        flushInline();
        widgets.add(_buildElement(context, node, style));
      }
    }
    flushInline();
    return widgets;
  }

  Widget _buildFlow(
    BuildContext context,
    List<html_dom.Node> nodes,
    TextStyle style, {
    TextAlign textAlign = TextAlign.start,
  }) {
    final children = _buildFlowChildren(
      context,
      nodes,
      style,
      textAlign: textAlign,
    );
    if (children.isEmpty) return const SizedBox.shrink();
    if (children.length == 1) return children.single;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }

  Widget _buildElement(
    BuildContext context,
    html_dom.Element element,
    TextStyle parentStyle,
  ) {
    final tag = _tagName(element);
    if (_ignoredTags.contains(tag)) return const SizedBox.shrink();

    if (tag == 'p') {
      final align = _parseTextAlign(element.attributes['align']);
      return Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.md),
        child: _buildFlow(
          context,
          element.nodes,
          parentStyle,
          textAlign: align,
        ),
      );
    }

    if (_headingTags.contains(tag)) {
      final headingStyle = _headingStyle(context, tag, parentStyle);
      final align = _parseTextAlign(element.attributes['align']);
      return Padding(
        padding: const EdgeInsets.only(
          top: AppSpacing.sm,
          bottom: AppSpacing.sm,
        ),
        child: _buildFlow(
          context,
          element.nodes,
          headingStyle,
          textAlign: align,
        ),
      );
    }

    if (tag == 'ul' || tag == 'ol') {
      return _buildList(context, element, parentStyle, depth: 0);
    }

    if (tag == 'blockquote') {
      final isDark = Theme.of(context).brightness == Brightness.dark;
      return Container(
        margin: const EdgeInsets.only(bottom: AppSpacing.md),
        padding: const EdgeInsets.only(left: AppSpacing.md),
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              color: isDark
                  ? AppColors.brandPrimary.withValues(alpha: 0.7)
                  : AppColors.brandPrimary.withValues(alpha: 0.45),
              width: 3,
            ),
          ),
        ),
        child: _buildFlow(context, element.nodes, parentStyle),
      );
    }

    if (tag == 'pre') {
      return _buildPre(context, element, parentStyle);
    }

    if (tag == 'table') {
      return _buildTable(context, element, parentStyle);
    }

    if (tag == 'img') {
      return _buildImage(context, element);
    }

    if (tag == 'hr') {
      final isDark = Theme.of(context).brightness == Brightness.dark;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        child: Divider(
          height: 1,
          color:
              isDark ? AppColors.borderNormalDark : AppColors.borderNormalLight,
        ),
      );
    }

    // div、figure、tbody 等容器只负责继续解析其子节点；不继承原站布局样式。
    return _buildFlow(context, element.nodes, parentStyle);
  }

  Widget _buildList(
    BuildContext context,
    html_dom.Element list,
    TextStyle style, {
    required int depth,
  }) {
    final tag = _tagName(list);
    final ordered = tag == 'ol';
    var index = int.tryParse(list.attributes['start'] ?? '') ?? 1;
    final items = list.children.where((child) => _tagName(child) == 'li');
    final children = <Widget>[];

    for (final item in items) {
      children.add(
        _buildListItem(
          context,
          item,
          style,
          ordered: ordered,
          index: index,
          depth: depth,
        ),
      );
      index++;
    }

    if (children.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Semantics(
        container: true,
        label: ordered ? '有序列表' : '无序列表',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    );
  }

  Widget _buildListItem(
    BuildContext context,
    html_dom.Element item,
    TextStyle style, {
    required bool ordered,
    required int index,
    required int depth,
  }) {
    final nestedLists = item.children.where(
      (child) => _tagName(child) == 'ul' || _tagName(child) == 'ol',
    );
    final contentNodes = item.nodes.where((node) {
      return node is! html_dom.Element ||
          (_tagName(node) != 'ul' && _tagName(node) != 'ol');
    }).toList();
    final marker = ordered ? '$index.' : '•';
    final content = <Widget>[
      _buildFlow(context, contentNodes, style),
      for (final nested in nestedLists)
        _buildList(context, nested, style, depth: depth + 1),
    ];

    return Padding(
      padding: EdgeInsets.only(
        left: depth * AppSpacing.lg,
        bottom: AppSpacing.xs,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 24,
            child: Text(marker, style: style),
          ),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: content,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPre(
    BuildContext context,
    html_dom.Element element,
    TextStyle parentStyle,
  ) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final text = element.text.trim();
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color:
            isDark ? AppColors.surfaceMutedDark : AppColors.surfaceMutedLight,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: SelectableText(
        text,
        style: parentStyle.copyWith(
          fontFamily: 'monospace',
          height: 1.5,
        ),
      ),
    );
  }

  Widget _buildImage(BuildContext context, html_dom.Element element) {
    final rawUrl = element.attributes['src'] ?? '';
    final uri = _resolveUri(rawUrl);
    final alt = (element.attributes['alt'] ?? '').trim();
    if (uri == null) {
      return alt.isEmpty
          ? const SizedBox.shrink()
          : Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.md),
              child: Text('[图片：$alt]'),
            );
    }

    final image = ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: CachedNetworkImage(
        imageUrl: uri.toString(),
        width: double.infinity,
        fit: BoxFit.contain,
        placeholder: (context, url) => Container(
          height: 160,
          color: Theme.of(context).brightness == Brightness.dark
              ? AppColors.surfaceMutedDark
              : AppColors.surfaceMutedLight,
          alignment: Alignment.center,
          child: const CircularProgressIndicator.adaptive(),
        ),
        errorWidget: (context, url, error) => Container(
          height: 96,
          color: Theme.of(context).brightness == Brightness.dark
              ? AppColors.surfaceMutedDark
              : AppColors.surfaceMutedLight,
          alignment: Alignment.center,
          child: const Icon(Icons.broken_image_outlined),
        ),
      ),
    );

    final tappable = widget.onOpenImage == null
        ? image
        : Semantics(
            button: true,
            label: alt.isEmpty ? '查看图片' : '查看图片：$alt',
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(AppRadius.sm),
                onTap: () => widget.onOpenImage!(uri.toString()),
                child: image,
              ),
            ),
          );

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: tappable,
    );
  }

  Widget _buildTable(
    BuildContext context,
    html_dom.Element table,
    TextStyle style,
  ) {
    final rows = _tableRows(table);
    if (rows.isEmpty) return const SizedBox.shrink();

    final grid = _makeTableGrid(rows);
    if (grid.isEmpty || grid.first.isEmpty) return const SizedBox.shrink();

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final borderColor =
        isDark ? AppColors.borderNormalDark : AppColors.borderNormalLight;
    final headerColor =
        isDark ? AppColors.brandSurfaceDark : AppColors.brandSurfaceLight;
    final columnCount = grid.first.length;

    final tableWidget = Table(
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      border: TableBorder.all(color: borderColor, width: 1),
      columnWidths: {
        for (var index = 0; index < columnCount; index++)
          index: const IntrinsicColumnWidth(),
      },
      children: [
        for (final row in grid)
          TableRow(
            children: [
              for (final cell in row)
                if (cell == null)
                  const SizedBox.shrink()
                else
                  Container(
                    constraints: BoxConstraints(
                      minWidth: 72.0 * cell.colSpan,
                      maxWidth: 240.0 * cell.colSpan,
                      minHeight: 44.0 * cell.rowSpan,
                    ),
                    color: cell.isHeader ? headerColor : null,
                    padding: const EdgeInsets.all(AppSpacing.sm),
                    child: _buildFlow(
                      context,
                      cell.element.nodes,
                      style.copyWith(
                        fontWeight:
                            cell.isHeader ? FontWeight.w700 : style.fontWeight,
                      ),
                    ),
                  ),
            ],
          ),
      ],
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Semantics(
        container: true,
        label: '横向可滚动表格',
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minWidth: MediaQuery.sizeOf(context).width - AppSpacing.lg * 2,
            ),
            child: tableWidget,
          ),
        ),
      ),
    );
  }

  List<html_dom.Element> _tableRows(html_dom.Element table) {
    final rows = <html_dom.Element>[];

    void visit(html_dom.Element element) {
      for (final child in element.children) {
        final tag = _tagName(child);
        if (tag == 'tr') {
          rows.add(child);
        } else if (tag != 'table') {
          visit(child);
        }
      }
    }

    visit(table);
    return rows;
  }

  List<List<_ArticleTableCell?>> _makeTableGrid(
    List<html_dom.Element> rows,
  ) {
    final grid = <List<_ArticleTableCell?>>[];
    final occupied = <int, Set<int>>{};

    void ensureSize(int rowCount, int columnCount) {
      while (grid.length < rowCount) {
        grid.add(<_ArticleTableCell?>[]);
      }
      for (final row in grid) {
        while (row.length < columnCount) {
          row.add(null);
        }
      }
    }

    bool fits(int row, int column, int rowSpan, int colSpan) {
      for (var r = row; r < row + rowSpan; r++) {
        final used = occupied[r] ?? const <int>{};
        for (var c = column; c < column + colSpan; c++) {
          if (used.contains(c)) return false;
        }
      }
      return true;
    }

    for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) {
      final row = rows[rowIndex];
      var column = 0;
      for (final element in row.children) {
        final tag = _tagName(element);
        if (tag != 'td' && tag != 'th') continue;

        final colSpan = _spanValue(element.attributes['colspan']);
        final rowSpan = _spanValue(element.attributes['rowspan']);
        while (!fits(rowIndex, column, rowSpan, colSpan)) {
          column++;
        }

        ensureSize(rowIndex + rowSpan, column + colSpan);
        final cell = _ArticleTableCell(
          element: element,
          colSpan: colSpan,
          rowSpan: rowSpan,
          isHeader: tag == 'th',
        );
        grid[rowIndex][column] = cell;
        for (var r = rowIndex; r < rowIndex + rowSpan; r++) {
          final used = occupied.putIfAbsent(r, () => <int>{});
          for (var c = column; c < column + colSpan; c++) {
            used.add(c);
          }
        }
        column += colSpan;
      }
    }

    final columnCount = grid.fold<int>(0, (max, row) {
      return row.length > max ? row.length : max;
    });
    ensureSize(grid.length, columnCount);
    return grid;
  }

  List<TextSpan> _buildInlineSpans(
    BuildContext context,
    List<html_dom.Node> nodes,
    TextStyle parentStyle,
  ) {
    final spans = <TextSpan>[];
    for (final node in nodes) {
      if (node is html_dom.Text) {
        final value = _normalizeInlineText(node.data);
        if (value.isNotEmpty) spans.add(TextSpan(text: value));
        continue;
      }
      if (node is! html_dom.Element) continue;

      final tag = _tagName(node);
      if (_ignoredTags.contains(tag) || tag == 'img') continue;
      if (tag == 'br') {
        spans.add(const TextSpan(text: '\n'));
        continue;
      }

      final childStyle = _inlineStyle(tag, parentStyle);
      final children = _buildInlineSpans(context, node.nodes, childStyle);
      if (children.isEmpty) continue;

      if (tag == 'a') {
        final rawUrl = node.attributes['href'] ?? '';
        final uri = _resolveUri(rawUrl);
        if (uri != null && widget.onOpenLink != null) {
          final recognizer = TapGestureRecognizer()
            ..onTap = () => widget.onOpenLink!(uri.toString());
          _recognizers.add(recognizer);
          spans.add(
            TextSpan(
              style: childStyle.copyWith(
                color: AppColors.brandPrimary,
                decoration: TextDecoration.underline,
                decorationColor: AppColors.brandPrimary,
              ),
              recognizer: recognizer,
              children: children,
            ),
          );
          continue;
        }
      }

      spans.add(TextSpan(style: childStyle, children: children));
    }
    return spans;
  }

  TextStyle _inlineStyle(String tag, TextStyle parent) {
    switch (tag) {
      case 'strong':
      case 'b':
        return parent.copyWith(fontWeight: FontWeight.w700);
      case 'em':
      case 'i':
        return parent.copyWith(fontStyle: FontStyle.italic);
      case 'u':
        return parent.copyWith(decoration: TextDecoration.underline);
      case 's':
      case 'del':
        return parent.copyWith(decoration: TextDecoration.lineThrough);
      case 'sup':
      case 'sub':
        return parent.copyWith(
          fontSize: (parent.fontSize ?? 16) * 0.75,
          height: 1,
        );
      default:
        return parent;
    }
  }

  TextStyle _headingStyle(
    BuildContext context,
    String tag,
    TextStyle bodyStyle,
  ) {
    final theme = Theme.of(context);
    final base = tag == 'h1'
        ? (theme.textTheme.headlineSmall ?? bodyStyle)
        : tag == 'h2' || tag == 'h3'
            ? (theme.textTheme.titleLarge ?? bodyStyle)
            : (theme.textTheme.titleMedium ?? bodyStyle);
    return base.copyWith(
      color: bodyStyle.color,
      height: 1.35,
      fontWeight: FontWeight.w700,
    );
  }

  TextAlign _parseTextAlign(String? value) {
    switch (value?.trim().toLowerCase()) {
      case 'center':
        return TextAlign.center;
      case 'right':
        return TextAlign.right;
      case 'justify':
        return TextAlign.justify;
      default:
        return TextAlign.start;
    }
  }

  Uri? _resolveUri(String rawUrl) {
    final raw = rawUrl.trim();
    if (raw.isEmpty) return null;
    final base = Uri.tryParse(widget.baseUrl);
    final uri = Uri.tryParse(raw);
    if (uri == null) return null;
    final resolved = uri.hasScheme || base == null ? uri : base.resolveUri(uri);
    if (resolved.scheme.toLowerCase() != 'https' ||
        resolved.host.isEmpty ||
        resolved.userInfo.isNotEmpty) {
      return null;
    }
    return resolved;
  }

  String _inlineText(List<html_dom.Node> nodes) {
    return nodes.map((node) {
      if (node is html_dom.Text) return node.data;
      if (node is html_dom.Element) return node.text;
      return '';
    }).join();
  }

  bool _hasVisibleInlineContent(List<html_dom.Node> nodes) {
    for (final node in nodes) {
      if (node is html_dom.Text && node.data.trim().isNotEmpty) return true;
      if (node is html_dom.Element) {
        final tag = _tagName(node);
        if (tag == 'br') return true;
        if (tag != 'img' && _hasVisibleInlineContent(node.nodes)) return true;
      }
    }
    return false;
  }

  String _normalizeInlineText(String value) {
    return value.replaceAll('\u00a0', ' ').replaceAll(RegExp(r'\s+'), ' ');
  }

  String _tagName(html_dom.Element element) =>
      (element.localName ?? '').toLowerCase();

  int _spanValue(String? raw) {
    final value = int.tryParse(raw ?? '') ?? 1;
    return value.clamp(1, 12).toInt();
  }
}

const _headingTags = <String>{'h1', 'h2', 'h3', 'h4', 'h5', 'h6'};
const _ignoredTags = <String>{
  'script',
  'style',
  'iframe',
  'object',
  'embed',
  'form',
  'input',
  'button',
  'select',
  'option',
  'textarea',
};

bool _isInlineTag(String tag) {
  return !_headingTags.contains(tag) &&
      tag != 'p' &&
      tag != 'div' &&
      tag != 'ul' &&
      tag != 'ol' &&
      tag != 'li' &&
      tag != 'blockquote' &&
      tag != 'pre' &&
      tag != 'table' &&
      tag != 'img' &&
      tag != 'hr' &&
      tag != 'figure' &&
      tag != 'figcaption';
}

class _ArticleTableCell {
  final html_dom.Element element;
  final int colSpan;
  final int rowSpan;
  final bool isHeader;

  const _ArticleTableCell({
    required this.element,
    required this.colSpan,
    required this.rowSpan,
    required this.isHeader,
  });
}

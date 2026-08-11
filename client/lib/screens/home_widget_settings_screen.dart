import 'package:flutter/material.dart';

import '../models/home_widget_config.dart';
import '../services/home_widget_service.dart';
import '../utils/app_feedback.dart';
import '../widgets/campus/campus_theme.dart';

class HomeWidgetSettingsScreen extends StatefulWidget {
  const HomeWidgetSettingsScreen({super.key});

  @override
  State<HomeWidgetSettingsScreen> createState() =>
      _HomeWidgetSettingsScreenState();
}

class _HomeWidgetSettingsScreenState extends State<HomeWidgetSettingsScreen>
    with WidgetsBindingObserver {
  final Map<HomeWidgetKind, HomeWidgetAppearance> _appearances = {};
  final Map<HomeWidgetKind, HomeWidgetPreviewData> _previews = {};
  final Map<HomeWidgetKind, HomeWidgetSize> _previewSizes = {
    HomeWidgetKind.course: HomeWidgetSize.size2x2,
    HomeWidgetKind.exam: HomeWidgetSize.size2x2,
  };
  HomeWidgetInstalledCounts _counts = const HomeWidgetInstalledCounts();
  bool _loading = true;
  bool _syncingAll = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      HomeWidgetService.getInstalledWidgetCounts().then((counts) {
        if (mounted) setState(() => _counts = counts);
      });
    }
  }

  @override
  void didChangePlatformBrightness() {
    super.didChangePlatformBrightness();
    final hasSystemTheme =
        _appearances.values.any((a) => a.theme == HomeWidgetTheme.system);
    if (hasSystemTheme) {
      HomeWidgetService.syncAll();
    }
  }

  Future<void> _load() async {
    final results = await Future.wait([
      HomeWidgetService.getAppearance(HomeWidgetKind.course),
      HomeWidgetService.getAppearance(HomeWidgetKind.exam),
      HomeWidgetService.getPreviewData(HomeWidgetKind.course),
      HomeWidgetService.getPreviewData(HomeWidgetKind.exam),
      HomeWidgetService.getInstalledWidgetCounts(),
    ]);
    if (!mounted) return;
    setState(() {
      _appearances[HomeWidgetKind.course] = results[0] as HomeWidgetAppearance;
      _appearances[HomeWidgetKind.exam] = results[1] as HomeWidgetAppearance;
      _previews[HomeWidgetKind.course] = results[2] as HomeWidgetPreviewData;
      _previews[HomeWidgetKind.exam] = results[3] as HomeWidgetPreviewData;
      _counts = results[4] as HomeWidgetInstalledCounts;
      _loading = false;
    });
  }

  Future<void> _updateAppearance(HomeWidgetAppearance next) async {
    setState(() => _appearances[next.kind] = next);
    await HomeWidgetService.updateAppearance(next);
  }

  Future<void> _editTitle(HomeWidgetKind kind) async {
    final appearance = _appearances[kind]!;
    final controller = TextEditingController(text: appearance.title);
    final dialogTheme = CampusTheme.withBrandAccent(Theme.of(context));
    final title = await showDialog<String>(
      context: context,
      builder: (dialogContext) => Theme(
        data: dialogTheme,
        child: AlertDialog(
          title: Text('${_kindTitle(kind)}标题'),
          content: TextField(
            controller: controller,
            autofocus: true,
            maxLength: 12,
            decoration: const InputDecoration(
              labelText: '小组件标题',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(controller.text),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (title == null) return;
    await _updateAppearance(
      appearance.copyWith(
          title: title.trim().isEmpty ? kind.defaultTitle : title),
    );
  }

  Future<void> _requestPin(
    HomeWidgetKind kind,
    HomeWidgetSize size,
  ) async {
    final result = await HomeWidgetService.requestPinWidget(kind, size);
    if (!mounted) return;
    final message = switch (result.status) {
      HomeWidgetPinStatus.requested => '已向桌面发送添加请求，请在系统确认后查看桌面。',
      HomeWidgetPinStatus.unsupported => '当前桌面不支持应用内添加，请长按桌面进入“小组件”添加。',
      HomeWidgetPinStatus.rejected => '桌面未接受添加请求，请长按桌面手动添加。',
      HomeWidgetPinStatus.failed =>
        result.message == null ? '添加请求失败，请稍后重试。' : '添加请求失败：${result.message}',
    };
    AppFeedback.info(message, context: context);
  }

  Future<void> _syncKind(HomeWidgetKind kind) async {
    await HomeWidgetService.syncKind(kind);
    final preview = await HomeWidgetService.getPreviewData(kind);
    final counts = await HomeWidgetService.getInstalledWidgetCounts();
    if (!mounted) return;
    setState(() {
      _previews[kind] = preview;
      _counts = counts;
    });
    AppFeedback.success('${_kindTitle(kind)}已同步', context: context);
  }

  Future<void> _syncAll() async {
    if (_syncingAll) return;
    setState(() => _syncingAll = true);
    await HomeWidgetService.syncAll();
    await _load();
    if (!mounted) return;
    setState(() => _syncingAll = false);
    AppFeedback.success('全部桌面小组件已同步', context: context);
  }

  @override
  Widget build(BuildContext context) {
    final baseTheme = Theme.of(context);
    final pageBackground = CampusTheme.pageBackground(context);

    return Theme(
      data: CampusTheme.withBrandAccent(baseTheme),
      child: Scaffold(
        backgroundColor: pageBackground,
        appBar: AppBar(
          title: const Text('桌面小组件'),
          backgroundColor: pageBackground,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                physics: const BouncingScrollPhysics(),
                children: [
                  _buildKindSection(HomeWidgetKind.course),
                  const SizedBox(height: 20),
                  _buildKindSection(HomeWidgetKind.exam),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: _syncingAll ? null : _syncAll,
                    icon: _syncingAll
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.sync),
                    label: const Text('同步全部小组件'),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '系统桌面的网格尺寸和圆角由启动器决定，实际占位可能与预览略有差异。',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildKindSection(HomeWidgetKind kind) {
    final appearance = _appearances[kind]!;
    final previewSize = _previewSizes[kind]!;
    final preview = _previews[kind] ?? const HomeWidgetPreviewData();
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      margin: const EdgeInsets.only(bottom: 24),
      decoration: BoxDecoration(
        color: isDark ? CampusTheme.darkCard : CampusTheme.card,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(isDark ? 0.2 : 0.04),
            blurRadius: 20,
            offset: const Offset(0, 4),
          ),
        ],
        border: Border.all(
          color: isDark ? Colors.white10 : CampusTheme.softBorder,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    _kindTitle(kind),
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                Text(
                  '已添加 ${_counts.totalFor(kind)} 个',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '布局预览',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: isDark ? Colors.white70 : CampusTheme.text,
                    ),
                  ),
                ),
                SegmentedButton<HomeWidgetSize>(
                  segments: const [
                    ButtonSegment(
                        value: HomeWidgetSize.size2x2,
                        label: Padding(
                            padding: EdgeInsets.symmetric(horizontal: 4),
                            child: Text('2×2',
                                style:
                                    TextStyle(fontWeight: FontWeight.w600)))),
                    ButtonSegment(
                        value: HomeWidgetSize.size4x2,
                        label: Padding(
                            padding: EdgeInsets.symmetric(horizontal: 4),
                            child: Text('4×2',
                                style:
                                    TextStyle(fontWeight: FontWeight.w600)))),
                  ],
                  selected: {previewSize},
                  onSelectionChanged: (set) =>
                      setState(() => _previewSizes[kind] = set.first),
                  style: SegmentedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    backgroundColor:
                        isDark ? Colors.white10 : CampusTheme.softBorder,
                    selectedBackgroundColor: isDark
                        ? const Color(0xFF1B3B36)
                        : CampusTheme.primaryLight,
                  ),
                  showSelectedIcon: false,
                ),
              ],
            ),
            const SizedBox(height: 16),
            _HomeWidgetPreview(
              kind: kind,
              size: previewSize,
              appearance: appearance,
              data: preview,
            ),
            const SizedBox(height: 16),
            const Text('主题', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final theme in HomeWidgetTheme.values)
                  ChoiceChip(
                    label: Text(theme.label),
                    selected: appearance.theme == theme,
                    onSelected: (_) => _updateAppearance(
                      appearance.copyWith(theme: theme),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            _WidgetSettingRow(
              title: '标题设置',
              subtitle: appearance.title,
              trailing: TextButton(
                onPressed: () => _editTitle(kind),
                child: const Text('修改'),
              ),
            ),
            const Divider(height: 1),
            _WidgetSizeRow(
              title: '2×2 紧凑版',
              subtitle: kind == HomeWidgetKind.course
                  ? '显示日期和最多 2 门课程'
                  : '显示最近 1～2 场考试与倒计时',
              count: _counts.countFor(kind, HomeWidgetSize.size2x2),
              onAdd: () => _requestPin(kind, HomeWidgetSize.size2x2),
            ),
            const Divider(height: 1),
            _WidgetSizeRow(
              title: '4×2 列表版',
              subtitle: kind == HomeWidgetKind.course
                  ? '显示更多课程、教师与地点'
                  : '显示更多考试的日期、时间与地点',
              count: _counts.countFor(kind, HomeWidgetSize.size4x2),
              onAdd: () => _requestPin(kind, HomeWidgetSize.size4x2),
            ),
            const Divider(height: 1),
            _WidgetSettingRow(
              title: '立即同步',
              subtitle: '刷新数据、主题、标题和倒计时',
              trailing: TextButton.icon(
                onPressed: () => _syncKind(kind),
                icon: const Icon(Icons.sync, size: 18),
                label: const Text('同步'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HomeWidgetPreview extends StatelessWidget {
  const _HomeWidgetPreview({
    required this.kind,
    required this.size,
    required this.appearance,
    required this.data,
  });

  final HomeWidgetKind kind;
  final HomeWidgetSize size;
  final HomeWidgetAppearance appearance;
  final HomeWidgetPreviewData data;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final palette = HomeWidgetThemePalette.resolve(
      appearance.theme,
      systemBrightness: Theme.of(context).brightness,
    );
    final isWide = size == HomeWidgetSize.size4x2;
    final maxItems = 2; // 无论是 2x2 还是 4x2，因为高度都是 2，最多只显示 2 条内容
    final items = data.items.take(maxItems).toList();

    return Container(
      width: double.infinity,
      height: 240,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        // 用渐变色模拟壁纸，让预览更逼真
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? [const Color(0xFF2C3E50), const Color(0xFF000000)]
              : [const Color(0xFFE0EAFC), const Color(0xFFCFDEF3)],
        ),
      ),
      child: Center(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
          width: isWide ? 310 : 170, // 增加基础宽度，避免内容被截断
          height: 155, // 微调高度使其更协调
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: palette.background,
            borderRadius: BorderRadius.circular(22),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.15),
                blurRadius: 15,
                offset: const Offset(0, 5),
              ),
            ],
            border: Border.all(color: palette.border, width: 0.5),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      appearance.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: palette.primaryText,
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  if (kind == HomeWidgetKind.course)
                    Text(
                      data.subtitle,
                      style:
                          TextStyle(color: palette.secondaryText, fontSize: 9),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Expanded(
                child: items.isEmpty
                    ? Center(
                        child: Text(
                          kind == HomeWidgetKind.course ? '今天没有课' : '近期暂无考试',
                          style:
                              TextStyle(color: palette.mutedText, fontSize: 11),
                        ),
                      )
                    : ListView.separated(
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: items.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 5),
                        itemBuilder: (context, index) {
                          final item = items[index];
                          return _PreviewItem(
                            item: item,
                            kind: kind,
                            detailed: isWide,
                            palette: palette,
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PreviewItem extends StatelessWidget {
  const _PreviewItem({
    required this.item,
    required this.kind,
    required this.detailed,
    required this.palette,
  });

  final HomeWidgetPreviewItem item;
  final HomeWidgetKind kind;
  final bool detailed;
  final HomeWidgetThemePalette palette;

  @override
  Widget build(BuildContext context) {
    Color barColor;
    try {
      barColor = Color(
        0xFF000000 | int.parse(item.color.replaceFirst('#', ''), radix: 16),
      );
    } catch (_) {
      barColor = palette.accent;
    }
    return SizedBox(
      height: detailed ? 48 : 42,
      child: Row(
        children: [
          Container(
            width: 3,
            decoration: BoxDecoration(
              color: kind == HomeWidgetKind.course ? barColor : palette.accent,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: palette.primaryText,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (item.badge.isNotEmpty)
                      Text(
                        item.badge,
                        style: TextStyle(
                          color: palette.accent,
                          fontSize: 8,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                  ],
                ),
                Text(
                  item.primaryDetail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: palette.secondaryText, fontSize: 9),
                ),
                if (detailed && item.secondaryDetail.isNotEmpty)
                  Text(
                    item.secondaryDetail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: palette.mutedText, fontSize: 8),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _WidgetSettingRow extends StatelessWidget {
  const _WidgetSettingRow({
    required this.title,
    required this.subtitle,
    required this.trailing,
  });

  final String title;
  final String subtitle;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          trailing,
        ],
      ),
    );
  }
}

class _WidgetSizeRow extends StatelessWidget {
  const _WidgetSizeRow({
    required this.title,
    required this.subtitle,
    required this.count,
    required this.onAdd,
  });

  final String title;
  final String subtitle;
  final int count;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
                if (count > 0)
                  Text('桌面已有 $count 个',
                      style: Theme.of(context).textTheme.labelSmall),
              ],
            ),
          ),
          TextButton(onPressed: onAdd, child: const Text('添加')),
        ],
      ),
    );
  }
}

String _kindTitle(HomeWidgetKind kind) => switch (kind) {
      HomeWidgetKind.course => '今日课表',
      HomeWidgetKind.exam => '考试日程',
    };

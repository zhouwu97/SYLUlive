import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../models/post.dart';
import '../../models/user.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_theme_tokens.dart';
import '../../theme/app_theme_style.dart';
import '../../widgets/ai/ai_input_composer.dart';
import '../../widgets/ai/ai_mode_switch.dart';
import '../../widgets/app_dialog.dart';
import '../../widgets/campus/campus_header.dart';
import '../../widgets/floating_bottom_nav.dart';
import '../../widgets/liquid_bottom_nav.dart';
import '../../widgets/market_post_card.dart';
import '../../widgets/opacity_safe_backdrop_filter.dart';
import '../../widgets/post_card.dart';
import '../../widgets/settings/settings_section.dart';
import '../../widgets/settings/settings_tile.dart';
import 'theme_appearance.dart';
import 'theme_manifest.dart';
import 'theme_navigation_images.dart';
import 'theme_presentation.dart';
import 'theme_widget_palette.dart';
import 'themed_wallpaper_layer.dart';

enum WorkshopSamplePage {
  home('首页'),
  market('集市'),
  schedule('课表'),
  campus('校园'),
  me('我'),
  userHome('个人主页'),
  settings('设置'),
  ai('AI 助手'),
  toolbox('工具箱');

  const WorkshopSamplePage(this.label);
  final String label;
}

enum WorkshopSampleState {
  normal('正常'),
  loading('加载'),
  empty('空态'),
  error('失败'),
  permission('权限');

  const WorkshopSampleState(this.label);
  final String label;
}

enum WorkshopFocusTarget {
  colors,
  courses,
  wallpaper,
  material,
  layoutHome,
  layoutCampus,
  layoutMe,
  decoHome,
  decoCampus,
  decoMe,
  icons,
  widgets,
}

final User _sampleAuthor = User(
  id: 1001,
  studentId: '2024010101',
  nickname: '沈理创作者',
  createdAt: DateTime(2026, 9, 1),
  exp: 360,
  creditScore: 100,
);

final Post _sampleFeedPost = Post(
  id: 9001,
  title: '图书馆三楼靠窗自习位光线真好',
  content: '今天下午阳光洒在桌面上，整理完了高数第三章笔记，大家期末复习加油。',
  boardId: 1,
  authorId: 1001,
  postType: 'study',
  likeCount: 28,
  replyCount: 6,
  viewCount: 142,
  isFeatured: true,
  author: _sampleAuthor,
  createdAt: DateTime(2026, 10, 18, 14, 30),
  updatedAt: DateTime(2026, 10, 18, 14, 30),
  lastActivityAt: DateTime(2026, 10, 18, 15, 10),
);

final Post _sampleMarketPost = Post(
  id: 9002,
  title: '出九成新教材《高等数学》上下册含习题解析',
  content: '无缺页少许工整笔记，文体馆门口或二食堂自提。',
  boardId: 2,
  authorId: 1001,
  postType: 'sell',
  price: 22.0,
  marketTags: const ['可小刀', '当面交易'],
  author: _sampleAuthor,
  createdAt: DateTime(2026, 10, 18, 12, 0),
  updatedAt: DateTime(2026, 10, 18, 12, 0),
  lastActivityAt: DateTime(2026, 10, 18, 12, 0),
);

/// 工坊上半屏实时组件预览舞台：复用正式页面共享组件与假数据，不发起任何网络请求。
class ThemeWorkshopSampleStage extends StatefulWidget {
  const ThemeWorkshopSampleStage({
    super.key,
    required this.appearance,
    required this.brightness,
    required this.assetResolver,
    required this.page,
    required this.sampleState,
    this.showDialogOverlay = false,
    this.onFocusTarget,
  });

  final ThemeAppearance appearance;
  final Brightness brightness;
  final ThemeAssetProviderResolver assetResolver;
  final WorkshopSamplePage page;
  final WorkshopSampleState sampleState;
  final bool showDialogOverlay;
  final ValueChanged<WorkshopFocusTarget>? onFocusTarget;

  @override
  State<ThemeWorkshopSampleStage> createState() =>
      _ThemeWorkshopSampleStageState();
}

class _ThemeWorkshopSampleStageState extends State<ThemeWorkshopSampleStage> {
  final ValueNotifier<double> _navVisual = ValueNotifier<double>(0);
  final TextEditingController _aiInputController = TextEditingController();
  bool _aiPersonalMode = false;

  @override
  void dispose() {
    _navVisual.dispose();
    _aiInputController.dispose();
    super.dispose();
  }

  String _wallpaperSlotFor(WorkshopSamplePage page) => switch (page) {
        WorkshopSamplePage.home => 'home',
        WorkshopSamplePage.schedule => 'schedule',
        WorkshopSamplePage.me => 'me',
        _ => 'global',
      };

  @override
  Widget build(BuildContext context) {
    final mode = widget.brightness == Brightness.dark ? 'dark' : 'light';
    final theme = widget.appearance.buildTheme(widget.brightness);
    final walls =
        widget.appearance.group(ThemeGroup.wallpapers)?[mode] as Map?;
    final preferredSlot = _wallpaperSlotFor(widget.page);
    final wallpaper =
        (walls?[preferredSlot] ?? walls?['global']) as Map<String, dynamic>?;

    final matGroup = widget.appearance.group(ThemeGroup.material);
    final modeMat = (matGroup != null && matGroup['legacy'] != true)
        ? matGroup[mode] as Map?
        : null;
    final cardOpacity = (modeMat?['componentOpacity'] as num? ?? 1.0)
        .toDouble()
        .clamp(0.0, 1.0);
    final frostMap = modeMat?['frostedGlass'] as Map?;
    final frostStrength = frostMap?['enabled'] == true
        ? ((frostMap?['strength'] as num?)?.toDouble() ?? 0.0).clamp(0.0, 1.0)
        : 0.0;

    final navigation = widget.appearance.group(ThemeGroup.navigation);
    final navImages = themeNavigationImages(
      navigation,
      imageProvider: (p) => widget.assetResolver(p) ?? AssetImage(p),
    );
    final originalIcons = navigation?['iconTint'] == 'original';
    final navTab = switch (widget.page) {
      WorkshopSamplePage.market => 1,
      WorkshopSamplePage.schedule => 2,
      WorkshopSamplePage.campus => 3,
      WorkshopSamplePage.me => 4,
      _ => 0,
    };
    _navVisual.value = navTab.toDouble();

    return ThemePresentationOverride(
      appearance: widget.appearance,
      brightnessOverride: widget.brightness,
      assetResolver: widget.assetResolver,
      child: Theme(
        data: theme,
        child: Builder(
          builder: (stageCtx) {
            final tokens = AppThemeTokens.of(stageCtx);
            final shape = AppShape.of(stageCtx);
            final showBottomNav = const {
              WorkshopSamplePage.home,
              WorkshopSamplePage.market,
              WorkshopSamplePage.schedule,
              WorkshopSamplePage.campus,
              WorkshopSamplePage.me,
            }.contains(widget.page);

            return ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: tokens.background,
                  border: Border.all(color: tokens.divider),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: ThemedWallpaperLayer(
                        settings: wallpaper,
                        imageProvider: wallpaper == null
                            ? null
                            : widget.assetResolver(
                                wallpaper['portrait'] as String,
                              ),
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildTopAppBar(tokens),
                        Expanded(
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                            child: widget.sampleState !=
                                    WorkshopSampleState.normal
                                ? _buildNonNormalState(
                                    stageCtx,
                                    tokens,
                                    shape,
                                    cardOpacity,
                                    frostStrength,
                                  )
                                : _buildPageBody(
                                    stageCtx,
                                    tokens,
                                    shape,
                                    cardOpacity,
                                    frostStrength,
                                  ),
                          ),
                        ),
                        if (showBottomNav)
                          GestureDetector(
                            behavior: HitTestBehavior.translucent,
                            onTap: () => widget.onFocusTarget
                                ?.call(WorkshopFocusTarget.icons),
                            child: navigation?['style'] == 'liquid_glass'
                                ? SizedBox(
                                    height: 84,
                                    child: LiquidBottomNav(
                                      currentIndex: navTab,
                                      visualIndexListenable: _navVisual,
                                      onTap: (_) => widget.onFocusTarget
                                          ?.call(WorkshopFocusTarget.icons),
                                      themeImages: navImages,
                                      originalIcons: originalIcons,
                                      shaderEnabled: false,
                                    ),
                                  )
                                : FloatingBottomNav(
                                    currentIndex: navTab,
                                    onTap: (_) => widget.onFocusTarget
                                        ?.call(WorkshopFocusTarget.icons),
                                    docked: navigation?['style'] == 'normal',
                                    themeImages: navImages,
                                    originalIcons: originalIcons,
                                  ),
                          ),
                      ],
                    ),
                    if (widget.showDialogOverlay)
                      Positioned.fill(
                        child: ColoredBox(
                          color: Colors.black.withValues(alpha: 0.32),
                          child: Center(
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: AppAlertDialog(
                                title: const Text('确认操作样例'),
                                content: const Text(
                                  '弹窗表面使用 surfaceElevated，内部控件不套用卡片几何描边覆盖。',
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () {},
                                    child: const Text('取消'),
                                  ),
                                  FilledButton(
                                    onPressed: () {},
                                    child: const Text('确认'),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildTopAppBar(AppThemeTokens tokens) {
    return Container(
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: tokens.appBarBackground,
        border: Border(bottom: BorderSide(color: tokens.divider)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '${widget.page.label} · ${widget.sampleState.label}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: tokens.appBarForeground,
              ),
            ),
          ),
          if (widget.onFocusTarget != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: tokens.tagBackground,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                '点选组件直达编辑',
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  color: tokens.tagText,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildNonNormalState(
    BuildContext context,
    AppThemeTokens tokens,
    AppShape shape,
    double cardOpacity,
    double frostStrength,
  ) {
    final (icon, title, subtitle, buttonLabel) = switch (widget.sampleState) {
      WorkshopSampleState.loading => (
          Icons.hourglass_top_rounded,
          '正在加载${widget.page.label}内容…',
          '骨架与进度指示器跟随 primary 与 surfaceMuted 语义色',
          null,
        ),
      WorkshopSampleState.empty => (
          Icons.inbox_outlined,
          '暂无${widget.page.label}数据',
          '空状态文字使用 textPrimary / textSecondary，保证清晰可读',
          '刷新看看',
        ),
      WorkshopSampleState.error => (
          Icons.cloud_off_rounded,
          '网络连接失败',
          '无法读取当前页面内容，请检查网络后重试',
          '重试',
        ),
      WorkshopSampleState.permission => (
          Icons.lock_outline_rounded,
          '请先完成教务认证',
          '权限提示不被任何主题装饰遮挡，按钮保持明确可点击',
          '前往授权',
        ),
      WorkshopSampleState.normal => (Icons.check, '', '', null),
    };

    return _wrapPreviewCard(
      context: context,
      tokens: tokens,
      shape: shape,
      opacity: cardOpacity,
      frostStrength: frostStrength,
      onTap: () => widget.onFocusTarget?.call(WorkshopFocusTarget.material),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.sampleState == WorkshopSampleState.loading)
            const SizedBox.square(
              dimension: 28,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            )
          else
            ThemeStateArt(
              enabled: widget.sampleState == WorkshopSampleState.empty ||
                  widget.sampleState == WorkshopSampleState.error,
              error: widget.sampleState == WorkshopSampleState.error,
              size: 96,
              fallback: Icon(icon, size: 36, color: tokens.primary),
            ),
          const SizedBox(height: 10),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: tokens.textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: tokens.textSecondary),
          ),
          if (buttonLabel != null) ...[
            const SizedBox(height: 12),
            FilledButton.tonal(
              onPressed: () {},
              child: Text(buttonLabel),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPageBody(
    BuildContext context,
    AppThemeTokens tokens,
    AppShape shape,
    double cardOpacity,
    double frostStrength,
  ) {
    switch (widget.page) {
      case WorkshopSamplePage.home:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            GestureDetector(
              key: const ValueKey('workshop-preview-header-home'),
              behavior: HitTestBehavior.opaque,
              onTap: () =>
                  widget.onFocusTarget?.call(WorkshopFocusTarget.layoutHome),
              child: const HomeThemedHeaderBanner(feedModeLabel: '推荐'),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: tokens.searchFill,
                borderRadius: BorderRadius.circular(shape.pill),
              ),
              child: Row(
                children: [
                  Icon(Icons.search, size: 16, color: tokens.textTertiary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '搜索帖子标题或版块话题…',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: tokens.textTertiary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            GestureDetector(
              key: const ValueKey('workshop-preview-post-card'),
              behavior: HitTestBehavior.opaque,
              onTap: () =>
                  widget.onFocusTarget?.call(WorkshopFocusTarget.material),
              child: IgnorePointer(
                child: PostCard(
                  post: _sampleFeedPost,
                  variant: PostCardVariant.homeFeed,
                  disableAuthorNavigation: true,
                ),
              ),
            ),
          ],
        );
      case WorkshopSamplePage.market:
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => widget.onFocusTarget?.call(WorkshopFocusTarget.material),
          child: IgnorePointer(
            child: MarketPostCard(post: _sampleMarketPost),
          ),
        );
      case WorkshopSamplePage.schedule:
        final palette = ThemeWidgetPalette.paletteFromAppearance(
          widget.appearance,
          widget.brightness,
        );
        const sampleCourses = [
          ('高等数学 A', '主教 302'),
          ('大学物理实验', '实验楼 B204'),
          ('数据结构', '信息楼 408'),
          ('程序设计实践', '机房 C105'),
          ('线性代数', '主教 108'),
          ('英语听说', '外语楼 201'),
        ];
        return GestureDetector(
          key: const ValueKey('workshop-preview-schedule-grid'),
          behavior: HitTestBehavior.opaque,
          onTap: () => widget.onFocusTarget?.call(WorkshopFocusTarget.courses),
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: tokens.card.withValues(alpha: cardOpacity),
              borderRadius: BorderRadius.circular(shape.md),
              border: Border.all(color: tokens.timetableGrid),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    for (var d = 0; d < 3; d++)
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          decoration: BoxDecoration(
                            color: d == 1
                                ? tokens.timetableToday
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            const ['周一', '周二（今天）', '周三'][d],
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight:
                                  d == 1 ? FontWeight.w700 : FontWeight.w500,
                              color: tokens.textPrimary,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (var i = 0; i < sampleCourses.length; i++)
                      Builder(
                        builder: (_) {
                          final rawColor = palette.coursePalette[
                              i % palette.coursePalette.length];
                          final blockBg = Color.alphaBlend(
                            rawColor.withValues(alpha: 0.45),
                            tokens.background,
                          );
                          return Container(
                            width: 102,
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: blockBg,
                              borderRadius: BorderRadius.circular(shape.sm),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  sampleCourses[i].$1,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    color: tokens.courseCardText,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  sampleCourses[i].$2,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    color: tokens.courseCardText,
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
      case WorkshopSamplePage.campus:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            GestureDetector(
              key: const ValueKey('workshop-preview-header-campus'),
              behavior: HitTestBehavior.opaque,
              onTap: () =>
                  widget.onFocusTarget?.call(WorkshopFocusTarget.layoutCampus),
              child: CampusHeader(
                semester: '2026—2027学年 · 第一学期',
                date: DateTime(2026, 10, 18),
              ),
            ),
            const SizedBox(height: 10),
            _wrapPreviewCard(
              context: context,
              tokens: tokens,
              shape: shape,
              opacity: cardOpacity,
              frostStrength: frostStrength,
              onTap: () =>
                  widget.onFocusTarget?.call(WorkshopFocusTarget.material),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  for (final item in const [
                    (Icons.grade_outlined, '成绩查询'),
                    (Icons.event_note_outlined, '考试安排'),
                    (Icons.restaurant_outlined, '食堂指南'),
                    (Icons.map_outlined, '校园地图'),
                  ])
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircleAvatar(
                          radius: 18,
                          backgroundColor: tokens.primaryContainer,
                          child: Icon(
                            item.$1,
                            size: 18,
                            color: tokens.onPrimaryContainer,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          item.$2,
                          style: TextStyle(
                            fontSize: 11.5,
                            color: tokens.textPrimary,
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ],
        );
      case WorkshopSamplePage.me:
      case WorkshopSamplePage.userHome:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            GestureDetector(
              key: const ValueKey('workshop-preview-header-me'),
              behavior: HitTestBehavior.opaque,
              onTap: () =>
                  widget.onFocusTarget?.call(WorkshopFocusTarget.layoutMe),
              child: ThemeHeaderFrame(
                slot: 'me',
                defaultBuilder: (_) =>
                    _buildMeCard(tokens, shape, compact: false),
                standardInfoBuilder: (_, __) =>
                    _buildMeCard(tokens, shape, compact: false),
                compactInfoBuilder: (_, __) =>
                    _buildMeCard(tokens, shape, compact: true),
              ),
            ),
            const SizedBox(height: 10),
            _wrapPreviewCard(
              context: context,
              tokens: tokens,
              shape: shape,
              opacity: cardOpacity,
              frostStrength: frostStrength,
              onTap: () =>
                  widget.onFocusTarget?.call(WorkshopFocusTarget.material),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  for (final stat in const [
                    ('18', '内容'),
                    ('64', '获赞'),
                    ('12', '关注'),
                  ])
                    Column(
                      children: [
                        Text(
                          stat.$1,
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 16,
                            color: tokens.textPrimary,
                          ),
                        ),
                        Text(
                          stat.$2,
                          style: TextStyle(
                            fontSize: 11.5,
                            color: tokens.textSecondary,
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ],
        );
      case WorkshopSamplePage.settings:
        return SettingsSection(
          title: '设置样例',
          children: [
            SettingsTile(
              icon: Icons.palette_outlined,
              title: '界面与主题设置',
              subtitle: '语义颜色与圆角自动同步到所有设置分组卡片',
              onTap: () =>
                  widget.onFocusTarget?.call(WorkshopFocusTarget.colors),
            ),
            SettingsTile(
              icon: Icons.notifications_none_rounded,
              title: '消息通知提醒',
              subtitle: '课程与考试提醒处于开启状态',
              onTap: () {},
            ),
          ],
        );
      case WorkshopSamplePage.ai:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AiModeSwitch(
              isPersonalMode: _aiPersonalMode,
              onModeChanged: (v) => setState(() => _aiPersonalMode = v),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: tokens.bubbleOutgoing,
                  borderRadius: BorderRadius.circular(shape.md),
                ),
                child: Text(
                  '帮我看看今天下午有什么课？',
                  style: TextStyle(
                    fontSize: 13,
                    color: tokens.bubbleOutgoingText,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: tokens.bubbleIncoming,
                  borderRadius: BorderRadius.circular(shape.md),
                ),
                child: Text(
                  '下午 13:30 在主教 302 有《高等数学 A》。',
                  style: TextStyle(
                    fontSize: 13,
                    color: tokens.bubbleIncomingText,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            AiInputComposer(
              controller: _aiInputController,
              maxCharacters: 500,
              enabled: true,
              running: false,
              hintText: '输入校园问题…',
              onSend: (_) {},
            ),
          ],
        );
      case WorkshopSamplePage.toolbox:
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final tool in const [
              (Icons.calculate_outlined, '绩点计算器'),
              (Icons.calendar_today_outlined, '校历速查'),
              (Icons.timer_outlined, '番茄自习钟'),
              (Icons.school_outlined, '空教室查询'),
            ])
              SizedBox(
                width: 150,
                child: _wrapPreviewCard(
                  context: context,
                  tokens: tokens,
                  shape: shape,
                  opacity: cardOpacity,
                  frostStrength: frostStrength,
                  onTap: () =>
                      widget.onFocusTarget?.call(WorkshopFocusTarget.material),
                  child: Row(
                    children: [
                      Icon(tool.$1, size: 20, color: tokens.primary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          tool.$2,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: tokens.textPrimary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
    }
  }

  Widget _buildMeCard(
    AppThemeTokens tokens,
    AppShape shape, {
    required bool compact,
  }) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: 14,
        vertical: compact ? 8 : 12,
      ),
      decoration: BoxDecoration(
        color: tokens.card,
        borderRadius: BorderRadius.circular(shape.lg),
        border: Border.all(color: tokens.cardBorder),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: compact ? 18 : 24,
            backgroundColor: tokens.primaryContainer,
            child: Icon(Icons.person, color: tokens.onPrimaryContainer),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '沈理创作者',
                  style: TextStyle(
                    fontSize: compact ? 14.5 : 17,
                    fontWeight: FontWeight.w700,
                    color: tokens.textPrimary,
                  ),
                ),
                Text(
                  '信息科学与工程学院 · Lv.4',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: tokens.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _wrapPreviewCard({
    required BuildContext context,
    required AppThemeTokens tokens,
    required AppShape shape,
    required double opacity,
    required double frostStrength,
    required Widget child,
    VoidCallback? onTap,
  }) {
    final cardStyle = ThemeCardStyleSpec.resolve(context);
    final radius = BorderRadius.circular(shape.md);
    final shadows = cardStyle?.resolveBoxShadows(
      widget.brightness == Brightness.dark,
    );
    final border = cardStyle?.resolveBoxBorder(tokens.cardBorder) ??
        Border.all(color: tokens.cardBorder);

    return GestureDetector(
      key: const ValueKey('workshop-preview-card'),
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        decoration: (shadows != null && shadows.isNotEmpty)
            ? BoxDecoration(borderRadius: radius, boxShadow: shadows)
            : null,
        child: ClipRRect(
          borderRadius: radius,
          child: OpacitySafeBackdropFilter(
            enabled: frostStrength > 0,
            filter: ui.ImageFilter.blur(
              sigmaX: 10 * frostStrength,
              sigmaY: 10 * frostStrength,
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: tokens.card.withValues(alpha: opacity),
                borderRadius: radius,
                border: border == const Border() ? null : border,
              ),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 导出用的 360×780 离屏渲染卡片（pixelRatio 3.0 生成 1080×2340 PNG）。
class ThemeWorkshopExportStage extends StatelessWidget {
  const ThemeWorkshopExportStage({
    super.key,
    required this.appearance,
    required this.brightness,
    required this.assetResolver,
  });

  final ThemeAppearance appearance;
  final Brightness brightness;
  final ThemeAssetProviderResolver assetResolver;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 360,
      height: 780,
      child: MediaQuery(
        data: const MediaQueryData(
          size: Size(360, 780),
          devicePixelRatio: 3.0,
          disableAnimations: true,
        ),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: ThemeWorkshopSampleStage(
            appearance: appearance,
            brightness: brightness,
            assetResolver: assetResolver,
            page: WorkshopSamplePage.home,
            sampleState: WorkshopSampleState.normal,
          ),
        ),
      ),
    );
  }
}

/// 工坊“小部件”只读预览：按契约 3.1 同时展示亮色与暗色下的课表和考试桌面小部件效果。
class ThemeWorkshopWidgetPreviewPanel extends StatelessWidget {
  const ThemeWorkshopWidgetPreviewPanel({
    super.key,
    required this.appearance,
  });

  final ThemeAppearance appearance;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          '小部件选择“跟随 App 主题”时，系统按明暗模式自动切换以下两套配色与课程色板：',
          style: TextStyle(fontSize: 12.5),
        ),
        const SizedBox(height: 12),
        for (final brightness in Brightness.values) ...[
          Text(
            brightness == Brightness.light ? '浅色桌面小部件预览' : '深色桌面小部件预览',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 6),
          _buildBrightnessPair(brightness),
          const SizedBox(height: 12),
        ],
      ],
    );
  }

  Widget _buildBrightnessPair(Brightness brightness) {
    final mode = brightness == Brightness.dark ? 'dark' : 'light';
    final matGroup = appearance.group(ThemeGroup.material);
    final frostEnabled = (matGroup != null && matGroup['legacy'] != true) &&
        ((matGroup[mode] as Map?)?['frostedGlass'] as Map?)?['enabled'] == true;
    final palette = ThemeWidgetPalette.paletteFromAppearance(
      appearance,
      brightness,
    );
    final mapped = ThemeWidgetPalette.variantFromPalette(
      palette,
      frostedGlass: frostEnabled,
    );
    final bg = palette.card.withAlpha(
      frostEnabled ? ThemeWidgetPalette.frostedAlphaByte : 0xFF,
    );

    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        Container(
          width: 220,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: palette.divider),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '今日课表',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: palette.textPrimary,
                    ),
                  ),
                  Text(
                    '第8周',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: palette.primary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              for (var i = 0; i < 2; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                    decoration: BoxDecoration(
                      color: palette.coursePalette[
                              i % palette.coursePalette.length]
                          .withValues(alpha: 0.25),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 3,
                          height: 22,
                          decoration: BoxDecoration(
                            color: palette.coursePalette[
                                i % palette.coursePalette.length],
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            i == 0 ? '08:00 高等数学 A' : '10:05 数据结构',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              color: palette.textPrimary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              Text(
                'BG ${mapped['background']} · Accent ${mapped['accent']}',
                style: TextStyle(fontSize: 9.5, color: palette.textTertiary),
              ),
            ],
          ),
        ),
        Container(
          width: 180,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: palette.divider),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '考试倒计时',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: palette.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '高等数学期末',
                style: TextStyle(
                  fontSize: 12,
                  color: palette.textSecondary,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '还有 14 天',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: palette.primary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

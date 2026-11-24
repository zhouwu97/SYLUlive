import '../theme/app_theme_tokens.dart';
import '../widgets/app_page_background.dart';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import '../theme/app_theme_style.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../platform/contracts/external_navigator.dart';
import '../app_bootstrap.dart';
import '../providers/auth_provider.dart';
import '../providers/edu_provider.dart';
import '../providers/theme_provider.dart';
import '../theme/app_palette.dart';
import '../widgets/glass_container.dart';
import '../services/physical_credential_store.dart';
import '../services/publish_session_scope.dart';
import 'erke_score_screen.dart';
import 'physical_test_screen.dart';
import 'lottery_screen.dart';
import 'exam_schedule_screen.dart';
import 'exam_papers/exam_paper_library_screen.dart';
import '../widgets/app_card.dart';

class ToolboxScreen extends StatefulWidget {
  const ToolboxScreen({super.key});

  @override
  State<ToolboxScreen> createState() => _ToolboxScreenState();
}

class _ToolboxScreenState extends State<ToolboxScreen> {
  static const List<_WebsiteDirectoryItem> _websiteDirectoryItems = [
    _WebsiteDirectoryItem(
      title: '省大创平台',
      subtitle: '创新创业训练计划',
      icon: Icons.lightbulb_outline,
      color: Color(0xFF55B97A), // theme: fixed 工具入口、网站入口分类识别色
      url: 'https://cxcy.upln.cn/',
    ),
    _WebsiteDirectoryItem(
      title: '教务处',
      subtitle: '教务通知与公告',
      icon: Icons.school_outlined,
      color: Color(0xFF826FE8), // theme: fixed 工具入口、网站入口分类识别色
      url: 'https://jwc.sylu.edu.cn/',
    ),
    _WebsiteDirectoryItem(
      title: '创院',
      subtitle: '创新创业学院',
      icon: Icons.emoji_events_outlined,
      color: Color(0xFFE9A23B), // theme: fixed 工具入口、网站入口分类识别色
      url: 'https://cxcyxy.sylu.edu.cn/',
    ),
    _WebsiteDirectoryItem(
      title: '查二课',
      subtitle: 'WebVPN 入口',
      icon: Icons.vpn_key_outlined,
      color: Color(0xFF35B7C4), // theme: fixed 工具入口、网站入口分类识别色
      url: 'https://webvpn.sylu.edu.cn/',
    ),
    _WebsiteDirectoryItem(
      title: '图书馆',
      subtitle: '馆藏与资源服务',
      icon: Icons.local_library_outlined,
      color: Color(0xFF5B8DEF), // theme: fixed 工具入口、网站入口分类识别色
      url: 'https://tsg.sylu.edu.cn/',
    ),
    _WebsiteDirectoryItem(
      title: '沈理就业网',
      subtitle: '招聘就业信息',
      icon: Icons.work_outline,
      color: Color(0xFFEE5C8A), // theme: fixed 工具入口、网站入口分类识别色
      url: 'https://job.sylu.edu.cn/',
    ),
    _WebsiteDirectoryItem(
      title: '蓝桥杯成绩',
      subtitle: '竞赛成绩快速查询',
      icon: Icons.military_tech_outlined,
      color: Color(0xFF0EA5A4), // theme: fixed 工具入口、网站入口分类识别色
      url: 'https://c16h22o4.github.io/',
    ),
    _WebsiteDirectoryItem(
      title: '四六级',
      subtitle: 'CET 报名与成绩查询',
      icon: Icons.translate,
      color: Color(0xFF0EA5E9), // theme: fixed 工具入口、网站入口分类识别色
      url: 'https://cet.neea.edu.cn/',
    ),
    _WebsiteDirectoryItem(
      title: '计算机等级考试',
      subtitle: 'NCRE 报名与证书查询',
      icon: Icons.computer_outlined,
      color: Color(0xFF6366F1), // theme: fixed 工具入口、网站入口分类识别色
      url: 'https://ncre.neea.edu.cn/',
    ),
    _WebsiteDirectoryItem(
      title: '教师资格证',
      subtitle: 'NTCE 报名与认定',
      icon: Icons.history_edu_outlined,
      color: Color(0xFFEF4444), // theme: fixed 工具入口、网站入口分类识别色
      url: 'https://ntce.neea.edu.cn/',
    ),
  ];

  @override
  void initState() {
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final themeProvider = context.watch<ThemeProvider>();
    final useCustomBackground = themeProvider.needsPhotoContrast;
    final cleanLightMode = !useCustomBackground && !isDark;
    final foregroundColor = useCustomBackground
        ? Colors.white // theme: fixed 壁纸覆盖层对比前景
        : AppThemeTokens.of(context).appBarForeground;
    final secondaryColor = useCustomBackground
        ? Colors.white // theme: fixed 壁纸覆盖层对比前景
        : AppThemeTokens.of(context).textSecondary;

    return GlobalBackgroundWrapper(
      child: Scaffold(
        backgroundColor: AppPageBackground.color(
            context, AppThemeTokens.of(context).background),
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          centerTitle: false,
          foregroundColor: foregroundColor,
          systemOverlayStyle: (cleanLightMode
                  ? SystemUiOverlayStyle.dark
                  : SystemUiOverlayStyle.light)
              .copyWith(
            statusBarColor: Colors.transparent,
            systemNavigationBarColor: Colors.transparent,
          ),
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          surfaceTintColor: Colors.transparent,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '工具箱',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  color: foregroundColor,
                  shadows: [
                    if (useCustomBackground)
                      const Shadow(
                        color: Colors
                            .black45, // theme: fixed 图片覆盖层对比色、固定光照阴影；B17/B18 只改简洁模式文字
                        blurRadius: 8,
                      ),
                  ],
                ),
              ),
              Text(
                '学习、查询与校园工具',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w400,
                  color: secondaryColor,
                ),
              ),
            ],
          ),
        ),
        body: Stack(
          children: [
            if (useCustomBackground)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: 150,
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors
                            .black54, // theme: fixed 图片覆盖层对比色、固定光照阴影；B17/B18 只改简洁模式文字
                        Colors.transparent,
                      ],
                    ),
                  ),
                ),
              ),
            SafeArea(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1000),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      int crossAxisCount = 1;
                      if (constraints.maxWidth >= 900) {
                        crossAxisCount = 4;
                      } else if (constraints.maxWidth >= 600) {
                        crossAxisCount = 3;
                      } else if (constraints.maxWidth >= 380) {
                        crossAxisCount = 2;
                      } else {
                        crossAxisCount = 1;
                      }

                      final tools = ListView(
                        // 毛玻璃依赖列表外的壁纸，滚动时保持与背景一起合成。
                        addRepaintBoundaries: false,
                        padding: const EdgeInsets.all(20),
                        children: [
                          _buildSectionTitle(
                            '常用工具',
                            isDark,
                            useCustomBackground,
                          ),
                          const SizedBox(height: 12),
                          _buildToolGrid(
                            width: constraints.maxWidth - 40,
                            columns: crossAxisCount,
                            children: [
                              _buildToolCard(
                                context,
                                icon: Icons.school_outlined,
                                color: const Color(
                                    0xFF55B97A), // theme: fixed 工具入口、网站入口分类识别色
                                title: '二课分查询',
                                themeKey: 'erke',
                                subtitle: '支持 WebVPN 穿透',
                                onTap: () => _openErke(context),
                              ),
                              _buildToolCard(
                                context,
                                icon: Icons.fitness_center,
                                color: const Color(
                                    0xFFE9A23B), // theme: fixed 工具入口、网站入口分类识别色
                                title: '体测成绩',
                                themeKey: 'fitness',
                                subtitle: '扫码核验 / 查询',
                                onTap: () => _openPhysicalTest(context),
                              ),
                              _buildToolCard(
                                context,
                                icon: Icons.event_note,
                                color: const Color(
                                    0xFF826FE8), // theme: fixed 工具入口、网站入口分类识别色
                                title: '考试日程',
                                themeKey: 'exam',
                                subtitle: 'AI一键提取',
                                onTap: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => const ExamScheduleScreen(),
                                  ),
                                ),
                              ),
                              _buildToolCard(
                                context,
                                icon: Icons.library_books_outlined,
                                color: const Color(
                                    0xFFEC6F5B), // theme: fixed 工具入口、网站入口分类识别色
                                title: '试卷库',
                                themeKey: 'papers',
                                subtitle: '历年试卷 / 投稿审核',
                                onTap: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) =>
                                        const ExamPaperLibraryScreen(),
                                  ),
                                ),
                              ),
                              _buildToolCard(
                                context,
                                icon: Icons.travel_explore_outlined,
                                color: const Color(
                                    0xFF4F8DF7), // theme: fixed 工具入口、网站入口分类识别色
                                title: '网站大全',
                                themeKey: 'sites',
                                subtitle: '用得到的网站',
                                onTap: () => _showWebsiteDirectory(context),
                              ),
                            ],
                          ),
                          const SizedBox(height: 24),
                          _buildSectionTitle(
                            '校园与娱乐',
                            isDark,
                            useCustomBackground,
                          ),
                          const SizedBox(height: 12),
                          _buildToolGrid(
                            width: constraints.maxWidth - 40,
                            columns: crossAxisCount,
                            children: [
                              _buildToolCard(
                                context,
                                icon: Icons.sports_esports,
                                color: const Color(
                                    0xFF35B7C4), // theme: fixed 工具入口、网站入口分类识别色
                                title: '云原神',
                                themeKey: 'cloudGame',
                                subtitle: '点击即玩',
                                onTap: () => _launchCloudGenshin(context),
                              ),
                              _buildToolCard(
                                context,
                                icon: Icons.card_giftcard,
                                color: const Color(
                                    0xFFEE5C8A), // theme: fixed 工具入口、网站入口分类识别色
                                title: '抽奖活动',
                                themeKey: 'lottery',
                                subtitle: '公平福利派送',
                                onTap: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                      builder: (_) => const LotteryScreen()),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 24),
                          _buildMoreToolsCard(isDark),
                        ],
                      );
                      return ScrollConfiguration(
                        // Android 的边缘拉伸会把列表放入离屏层，隔断壁纸采样。
                        behavior: themeProvider.frostedGlass
                            ? ScrollConfiguration.of(context)
                                .copyWith(overscroll: false)
                            : ScrollConfiguration.of(context),
                        child: tools,
                      );
                    },
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 这些网格不独立滚动。Wrap 避免嵌套 viewport 被单独缓存，
  // 让卡片的 BackdropFilter 始终采样外层壁纸，而非离屏透明层。
  Widget _buildToolGrid({
    required double width,
    required int columns,
    required List<Widget> children,
  }) {
    final cardWidth = (width - (columns - 1) * 12) / columns;
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        for (final card in children)
          SizedBox(width: cardWidth, height: 88, child: card),
      ],
    );
  }

  Widget _buildSectionTitle(
    String title,
    bool isDark,
    bool useCustomBackground,
  ) {
    return Text(
      title,
      style: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w700,
        color: AppThemeTokens.of(context).textPrimary,
        shadows: [
          if (useCustomBackground)
            Shadow(
              color: Colors.black.withValues(
                  alpha: 0.35), // theme: fixed 图片覆盖层对比色、固定光照阴影；B17/B18 只改简洁模式文字
              blurRadius: 6,
            ),
        ],
      ),
    );
  }

  Widget _buildMoreToolsCard(bool isDark) {
    return GlassContainer(
      borderRadius: AppShape.of(context).lg,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: const Color(0xFF5B8DEF) // theme: fixed 工具入口分类识别色
                  .withValues(alpha: 0.15), // theme: fixed 工具入口、网站入口分类识别色
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.auto_stories_outlined,
                color: Color(0xFF5B8DEF), // theme: fixed 工具入口分类识别色
                size: 22), // theme: fixed 工具入口、网站入口分类识别色
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '更多工具',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                    color: AppThemeTokens.of(context).textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '更多校园功能正在完善',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w400,
                    color: AppThemeTokens.of(context).textSecondary,
                  ),
                ),
              ],
            ),
          ),
          Text(
            '开发中',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: AppThemeTokens.of(context).textTertiary,
            ),
          ),
        ],
      ),
    );
  }

  void _openErke(BuildContext context) {
    if (context.read<AuthProvider>().user == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请先登录')));
      return;
    }
    Navigator.push(context,
        MaterialPageRoute(builder: (_) => const ErkeScoreScreen()));
  }

  void _openPhysicalTest(BuildContext context) {
    final auth = context.read<AuthProvider>();
    final academicStudentId =
        context.read<EduProvider?>()?.studentId.trim() ?? '';
    final username = academicStudentId.isNotEmpty
        ? academicStudentId
        : (auth.user?.studentId ?? '');
    final appUserId = auth.user?.id.toString() ?? '';
    if (username.isEmpty || appUserId.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先登录')));
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _PhysicalTestGate(
          appUserId: appUserId,
          username: username,
        ),
      ),
    );
  }

  void _launchCloudGenshin(BuildContext context) async {
    String url;
    if (kIsWeb) {
      url = 'https://ys.mihoyo.com/cloud/';
    } else if (Platform.isAndroid) {
      url = 'https://ys.mihoyo.com/cloud/';
    } else if (Platform.isIOS) {
      url = 'https://apps.apple.com/cn/app/id1569029742';
    } else {
      url = 'https://ys.mihoyo.com/cloud/';
    }

    final uri = Uri.parse(url);
    final opened = await ExternalNavigator.current().open(uri);
    if (!opened) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('无法打开链接')));
      }
    }
  }

  void _showWebsiteDirectory(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const _WebsiteDirectoryScreen(
          items: _websiteDirectoryItems,
        ),
      ),
    );
  }

  Widget _buildToolCard(
    BuildContext context, {
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    String? themeKey,
  }) {
    final themedIcon = AppThemeStyle.of(context).serviceIcon(context, themeKey);
    return GlassContainer(
      onTap: onTap,
      borderRadius: AppShape.of(context).lg,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          themedIcon ??
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: color, size: 22),
              ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                    color: AppThemeTokens.of(context).textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w400,
                    color: AppThemeTokens.of(context).textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _WebsiteDirectoryScreen extends StatelessWidget {
  const _WebsiteDirectoryScreen({required this.items});

  final List<_WebsiteDirectoryItem> items;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final themeProvider = context.watch<ThemeProvider>();
    final useCustomBackground = themeProvider.needsPhotoContrast;
    final cleanLightMode = !useCustomBackground && !isDark;
    final foregroundColor = useCustomBackground
        ? Colors.white // theme: fixed 壁纸覆盖层对比前景
        : AppThemeTokens.of(context).appBarForeground;
    final secondaryColor = useCustomBackground
        ? Colors.white70 // theme: fixed 壁纸覆盖层对比前景
        : AppThemeTokens.of(context).textSecondary;

    return GlobalBackgroundWrapper(
      child: Scaffold(
        backgroundColor: AppPageBackground.color(
            context, AppThemeTokens.of(context).background),
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          centerTitle: false,
          foregroundColor: foregroundColor,
          systemOverlayStyle: (cleanLightMode
                  ? SystemUiOverlayStyle.dark
                  : SystemUiOverlayStyle.light)
              .copyWith(
            statusBarColor: Colors.transparent,
            systemNavigationBarColor: Colors.transparent,
          ),
          backgroundColor: Colors.transparent,
          elevation: 0,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '网站大全',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: foregroundColor,
                  shadows: [
                    if (useCustomBackground)
                      const Shadow(
                          color: Colors.black45,
                          blurRadius:
                              8), // theme: fixed 图片覆盖层对比色、固定光照阴影；B17/B18 只改简洁模式文字
                  ],
                ),
              ),
              Text(
                '用得到的网站',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w400,
                  color: secondaryColor,
                ),
              ),
            ],
          ),
        ),
        body: Stack(
          children: [
            if (useCustomBackground)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: 150,
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black54,
                        Colors.transparent
                      ], // theme: fixed 图片覆盖层对比色、固定光照阴影；B17/B18 只改简洁模式文字
                    ),
                  ),
                ),
              ),
            SafeArea(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
                    children: [
                      Text(
                        '常用网站',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: AppThemeTokens.of(context).textPrimary,
                          shadows: [
                            if (useCustomBackground)
                              Shadow(
                                color: Colors.black.withValues(
                                    alpha:
                                        0.35), // theme: fixed 图片覆盖层对比色、固定光照阴影；B17/B18 只改简洁模式文字
                                blurRadius: 6,
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      ...items.map(
                        (item) => Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: _WebsiteDirectoryCard(item: item),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WebsiteDirectoryCard extends StatelessWidget {
  const _WebsiteDirectoryCard({required this.item});

  final _WebsiteDirectoryItem item;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final themeProvider = context.watch<ThemeProvider>();
    final useCustomBackground = themeProvider.shouldShowCustomBackground;
    final backgroundColor = AppThemeTokens.of(context)
        .card
        .withValues(alpha: !isDark && useCustomBackground ? 0.78 : 1);
    final borderColor = AppThemeTokens.of(context)
        .cardBorder
        .withValues(alpha: !isDark && useCustomBackground ? 0.65 : 1);

    return AppCardSurface(
      decoration: BoxDecoration(
          color: backgroundColor,
          borderRadius: BorderRadius.circular(AppShape.of(context).lg),
          border: Border.all(color: borderColor),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(
                    alpha:
                        0.06), // theme: fixed 图片覆盖层对比色、固定光照阴影；B17/B18 只改简洁模式文字
                blurRadius: 16,
                offset: const Offset(0, 6))
          ]),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppShape.of(context).lg),
          onTap: () => _openWebsiteDirectoryItem(context, item),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            child: Row(children: [
              Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                      color: AppThemeStyle.of(context).identity(item.color).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(13)),
                  child: Icon(item.icon,
                      color: AppThemeStyle.of(context).identity(item.color),
                      size: 23)),
              const SizedBox(width: 12),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: AppThemeTokens.of(context).textPrimary)),
                    const SizedBox(height: 4),
                    Text(item.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12,
                            color: AppThemeTokens.of(context).textSecondary))
                  ])),
              Icon(Icons.open_in_new,
                  size: 18, color: AppThemeTokens.of(context).textTertiary)
            ]),
          ),
        ),
      ),
    );
  }

  Future<void> _openWebsiteDirectoryItem(
    BuildContext context,
    _WebsiteDirectoryItem item,
  ) async {
    final uri = Uri.parse(item.url);
    final opened = await ExternalNavigator.current().open(uri);
    if (!opened && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无法打开链接')),
      );
    }
  }
}

class _WebsiteDirectoryItem {
  const _WebsiteDirectoryItem({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.color,
    required this.url,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
  final String url;
}

/// 体测密码输入门控 — 独立的 StatefulWidget，避免 controller 生命周期问题
class _PhysicalTestGate extends StatefulWidget {
  final String appUserId;
  final String username;
  const _PhysicalTestGate({required this.appUserId, required this.username});

  @override
  State<_PhysicalTestGate> createState() => _PhysicalTestGateState();
}

class _PhysicalTestGateState extends State<_PhysicalTestGate> {
  final _pwdCtrl = TextEditingController();
  bool _obscurePwd = true;
  bool _restoringPassword = true;
  bool _querying = false;
  late final PublishSessionScope _session;
  final PhysicalCredentialStore _credentialStore = PhysicalCredentialStore();

  @override
  void initState() {
    super.initState();
    final auth = context.read<AuthProvider>();
    _session = PublishSessionScope(
        accountId: auth.user!.id,
        accountSessionEpoch: auth.accountSessionEpoch);
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadSavedPassword());
  }

  @override
  void dispose() {
    _pwdCtrl.dispose();
    super.dispose();
  }

  bool get _isCurrent {
    if (!mounted) return false;
    final auth = context.read<AuthProvider>();
    final studentId = context.read<EduProvider?>()?.studentId.trim() ?? '';
    return auth.isLoggedIn &&
        auth.user?.id.toString() == widget.appUserId &&
        _session.owns(
            userId: auth.user?.id, sessionEpoch: auth.accountSessionEpoch) &&
        (studentId.isEmpty ? auth.user?.studentId : studentId) ==
            widget.username;
  }

  Future<void> _loadSavedPassword() async {
    try {
      final pwd = await _credentialStore.read(widget.username);
      if (!_isCurrent) return;
      setState(() => _restoringPassword = false);
      if (pwd != null && pwd.isNotEmpty) {
        _pwdCtrl.text = pwd;
        await _queryManual();
      }
    } catch (_) {
      if (!mounted || !_isCurrent) return;
      setState(() => _restoringPassword = false);
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('本机保存的密码暂时无法读取，请手动输入后重试')));
    }
  }

  Future<void> _queryManual() async {
    if (_restoringPassword || _querying || !_isCurrent) return;
    final pwd = _pwdCtrl.text;
    if (pwd.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请输入体测密码')));
      return;
    }
    setState(() => _querying = true);
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PhysicalTestPage(
          appUserId: widget.appUserId,
          username: widget.username,
          password: pwd,
        ),
      ),
    );
    if (mounted) setState(() => _querying = false);
  }

  @override
  Widget build(BuildContext context) {
    return AppPageBackground(
        builder: (context) => Scaffold(
              backgroundColor: AppPageBackground.color(
                  context, AppThemeTokens.of(context).background),
              appBar: AppBar(
                title: const Text('体测成绩查询'),
                backgroundColor: Colors.transparent,
                elevation: 0,
              ),
              body: SafeArea(
                child: SingleChildScrollView(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                  child: Column(
                    children: [
                      GlassContainer(
                        padding: const EdgeInsets.all(16),
                        borderRadius: 16,
                        child: Row(
                          children: [
                            const Icon(
                              Icons.info_outline,
                              color: Colors.blue, // theme: fixed 体测工具识别色
                              size: 20,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                '学号 ${widget.username} 已自动识别，请输入体测密码查询',
                                style: TextStyle(
                                  fontSize: 13,
                                  color:
                                      AppThemeTokens.of(context).textSecondary,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      GlassContainer(
                        padding: const EdgeInsets.all(20),
                        borderRadius: 20,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(
                                  Icons.fitness_center,
                                  color: Colors.blue, // theme: fixed 体测工具识别色
                                  size: 22,
                                ),
                                const SizedBox(width: 10),
                                const Text(
                                  '体测密码',
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const Spacer(),
                                Text(
                                  '初始密码默认为111111',
                                  style: TextStyle(
                                    fontSize: 10,
                                    color:
                                        AppThemeTokens.of(context).textTertiary,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 16),
                            TextField(
                              controller: _pwdCtrl,
                              enabled: !_restoringPassword && !_querying,
                              obscureText: _obscurePwd,
                              style: const TextStyle(fontSize: 14),
                              decoration: InputDecoration(
                                hintText: '输入体测系统密码',
                                prefixIcon:
                                    const Icon(Icons.lock_outline, size: 18),
                                suffixIcon: IconButton(
                                  icon: Icon(
                                    _obscurePwd
                                        ? Icons.visibility_off
                                        : Icons.visibility,
                                    size: 18,
                                  ),
                                  onPressed: () => setState(
                                      () => _obscurePwd = !_obscurePwd),
                                ),
                                filled: true,
                                fillColor: AppThemeTokens.of(context).inputFill,
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide.none,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 24),
                      SizedBox(
                        width: double.infinity,
                        height: 52,
                        child: ElevatedButton(
                          onPressed: _restoringPassword || _querying
                              ? null
                              : _queryManual,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Theme.of(context).primaryColor,
                            foregroundColor:
                                AppThemeTokens.of(context).onPrimary,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                            elevation: 0,
                          ),
                          child: Text(
                            _restoringPassword ? '正在读取已保存密码…' : '开始查询',
                            style: const TextStyle(
                                fontSize: 16, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ));
  }
}

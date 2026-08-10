import 'package:flutter/material.dart';
import '../../theme/app_motion.dart';
import '../../theme/app_radius.dart';
import 'campus_theme.dart';
import 'campus_service_item.dart';

class CampusServiceGrid extends StatefulWidget {
  final bool isDark;
  final VoidCallback onEduTap;
  final VoidCallback onRateTap;
  final VoidCallback onTeamTap;
  final VoidCallback onMapTap;
  final VoidCallback onCalendarTap;

  const CampusServiceGrid({
    super.key,
    required this.isDark,
    required this.onEduTap,
    required this.onRateTap,
    required this.onTeamTap,
    required this.onMapTap,
    required this.onCalendarTap,
  });

  @override
  State<CampusServiceGrid> createState() => _CampusServiceGridState();
}

class _CampusServiceGridState extends State<CampusServiceGrid>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entryController;
  bool _reduceMotion = false;
  bool _motionPreferenceSet = false;
  bool _entryScheduled = false;

  @override
  void initState() {
    super.initState();
    _entryController = AnimationController(
      vsync: this,
      duration: AppMotion.page,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (_motionPreferenceSet && _reduceMotion == reduceMotion) return;
    _motionPreferenceSet = true;
    _reduceMotion = reduceMotion;
    if (reduceMotion) {
      _entryController.value = 1;
      return;
    }
    if (_entryScheduled) return;
    _entryScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _reduceMotion) return;
      _entryController.forward();
    });
  }

  @override
  void dispose() {
    _entryController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final services = [
      CampusServiceItem(
        title: '教务中心',
        icon: Icons.school_rounded,
        color: CampusTheme.blue,
        onTap: widget.onEduTap,
      ),
      CampusServiceItem(
        title: '校园榜单',
        icon: Icons.leaderboard_rounded,
        color: CampusTheme.orange,
        onTap: widget.onRateTap,
      ),
      CampusServiceItem(
        title: '组队',
        icon: Icons.groups_2_rounded,
        color: CampusTheme.primary,
        onTap: widget.onTeamTap,
      ),
      CampusServiceItem(
        title: '校园地图',
        icon: Icons.map_rounded,
        color: CampusTheme.cyan,
        onTap: widget.onMapTap,
      ),
      CampusServiceItem(
        title: '校历',
        icon: Icons.calendar_month_rounded,
        color: CampusTheme.green,
        onTap: widget.onCalendarTap,
      ),
    ];
    final isDark = widget.isDark;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '校园服务',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w800,
            color: isDark ? Colors.white : CampusTheme.text,
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          '常用校园功能',
          style: TextStyle(
            fontSize: 12,
            color: CampusTheme.subText,
          ),
        ),
        const SizedBox(height: 12),
        Container(
          decoration: BoxDecoration(
            gradient: isDark
                ? const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [CampusTheme.darkCard, Color(0xFF20272A)],
                  )
                : const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Colors.white, Color(0xFFF7FCFA)],
                  ),
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.04)
                  : CampusTheme.primary.withValues(alpha: 0.08),
            ),
            boxShadow: [
              BoxShadow(
                color: (isDark ? Colors.black : CampusTheme.primary)
                    .withValues(alpha: isDark ? 0.18 : 0.06),
                blurRadius: 22,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Material(
            color: Colors.transparent,
            child: Row(
              children: [
                for (var index = 0; index < services.length; index++)
                  Expanded(
                    child: _buildAnimatedService(
                      services[index],
                      index,
                      isDark,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAnimatedService(
    CampusServiceItem service,
    int index,
    bool isDark,
  ) {
    final child = CampusServiceCard(service: service, isDark: isDark);
    if (_reduceMotion) return child;

    final begin = (index * 0.08).clamp(0.0, 0.35).toDouble();
    final end = (begin + 0.55).clamp(0.0, 1.0).toDouble();
    final animation = CurvedAnimation(
      parent: _entryController,
      curve: Interval(begin, end, curve: AppMotion.standard),
    );

    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, child) {
        final t = animation.value;
        return Opacity(
          opacity: 0.84 + (0.16 * t),
          child: Transform.translate(
            offset: Offset(0, 8 * (1 - t)),
            child: child,
          ),
        );
      },
    );
  }
}

import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../widgets/glass_container.dart';

class CampusCalendarScreen extends StatefulWidget {
  const CampusCalendarScreen({super.key});

  @override
  State<CampusCalendarScreen> createState() => _CampusCalendarScreenState();
}

class _CampusCalendarScreenState extends State<CampusCalendarScreen>
    with SingleTickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  bool _showControls = true;
  double _currentScale = 1.0;
  late AnimationController _fadeController;
  late Animation<double> _fadeAnimation;

  // Mock academic calendar data
  final List<_CalendarEvent> _events = [
    _CalendarEvent(
      title: '开学注册',
      date: DateTime(2026, 2, 24),
      color: const Color(0xFF3B82F6),
      icon: Icons.school_rounded,
    ),
    _CalendarEvent(
      title: '第一周教学',
      date: DateTime(2026, 2, 27),
      color: const Color(0xFF10B981),
      icon: Icons.book_rounded,
    ),
    _CalendarEvent(
      title: '期中考试',
      date: DateTime(2026, 4, 10),
      color: const Color(0xFFF59E0B),
      icon: Icons.edit_note_rounded,
    ),
    _CalendarEvent(
      title: '五一假期',
      date: DateTime(2026, 5, 1),
      color: const Color(0xFFEF4444),
      icon: Icons.beach_access_rounded,
    ),
    _CalendarEvent(
      title: '期末考试',
      date: DateTime(2026, 6, 20),
      color: const Color(0xFF8B5CF6),
      icon: Icons.assignment_rounded,
    ),
  ];

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _fadeController, curve: Curves.easeOut),
    );
    _fadeController.forward();
  }

  @override
  void dispose() {
    _fadeController.dispose();
    super.dispose();
  }

  void _toggleControls() {
    if (mounted) setState(() => _showControls = !_showControls);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = Theme.of(context).primaryColor;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          // Calendar image viewer
          GestureDetector(
            onTap: _toggleControls,
            child: InteractiveViewer(
              minScale: 0.5,
              maxScale: 4.0,
              onInteractionUpdate: (details) {
                if (mounted) setState(() {
                  _currentScale = details.scale;
                });
              },
              child: Center(
                child: AnimatedBuilder(
                  animation: _fadeAnimation,
                  builder: (context, child) {
                    return Opacity(
                      opacity: _fadeAnimation.value,
                      child: child,
                    );
                  },
                  child: Image.asset(
                    'assets/images/xiaoli.jpg',
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) =>
                        _buildContentView(isDark, primaryColor),
                  ),
                ),
              ),
            ),
          ),

          /* Removed Top gradient overlay to fix black shadow issue */

          /*
          // Bottom events panel
          if (_showControls)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: _buildEventsPanel(isDark, primaryColor),
            ),
          */
          if (false && _showControls)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: _buildEventsPanel(isDark, primaryColor),
            ),

          // Scale indicator
          if (_currentScale != 1.0 && !_showControls)
            Positioned(
              top: 100,
              left: 0,
              right: 0,
              child: Center(
                child: GlassContainer(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  borderRadius: 20,
                  blur: 8,
                  opacity: 0.3,
                  backgroundColor:
                      isDark ? const Color(0xFF1A1A2E) : Colors.white,
                  child: Text(
                    '${(_currentScale * 100).toInt()}%',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: isDark ? Colors.white : Colors.black87,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildEventsPanel(bool isDark, Color primaryColor) {
    final now = DateTime.now();
    final upcomingEvents = _events
        .where((e) => e.date.isAfter(now.subtract(const Duration(days: 7))))
        .toList()
      ..sort((a, b) => a.date.compareTo(b.date));

    return GlassContainer(
      borderRadius: 24.0,
      blur: 20,
      opacity: 0.35,
      backgroundColor:
          isDark ? const Color(0xFF1A1A2E) : Colors.white,
      borderColor: isDark
          ? Colors.white.withValues(alpha: 0.1)
          : Colors.black.withValues(alpha: 0.06),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle bar
          Container(
            width: 40,
            height: 4,
            margin: const EdgeInsets.only(top: 12, bottom: 16),
            decoration: BoxDecoration(
              color: isDark ? Colors.white24 : Colors.black12,
              borderRadius: BorderRadius.circular(2),
            ),
          ),

          // Header
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: primaryColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    Icons.event_rounded,
                    color: primaryColor,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  '重要日程',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                ),
                const Spacer(),
                Text(
                  '${upcomingEvents.length} 个',
                  style: TextStyle(
                    fontSize: 13,
                    color: isDark ? Colors.white54 : Colors.grey[600],
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // Events list
          if (upcomingEvents.isEmpty)
            Padding(
              padding: const EdgeInsets.all(20),
              child: Text(
                '暂无即将到来的日程',
                style: TextStyle(
                  fontSize: 14,
                  color: isDark ? Colors.white54 : Colors.grey[500],
                ),
              ),
            )
          else
            SizedBox(
              height: 120,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                itemCount: upcomingEvents.length,
                separatorBuilder: (_, __) => const SizedBox(width: 12),
                itemBuilder: (context, index) {
                  final event = upcomingEvents[index];
                  final isToday = _isSameDay(event.date, now);
                  final isPast = event.date.isBefore(now);
                  return _buildEventCard(event, isDark, isToday, isPast);
                },
              ),
            ),

          const SizedBox(height: 20),
        ],
      ),
    );
  }

  Widget _buildEventCard(
      _CalendarEvent event, bool isDark, bool isToday, bool isPast) {
    final daysUntil = event.date.difference(DateTime.now()).inDays;
    String timeLabel;
    if (isToday) {
      timeLabel = '今天';
    } else if (daysUntil == 1) {
      timeLabel = '明天';
    } else if (daysUntil < 7) {
      timeLabel = '$daysUntil 天后';
    } else {
      timeLabel = DateFormat('MM/dd').format(event.date);
    }

    return Container(
      width: 140,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.06)
            : Colors.black.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(16),
        border: isToday
            ? Border.all(color: event.color.withValues(alpha: 0.5), width: 2)
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: event.color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  event.icon,
                  size: 16,
                  color: event.color,
                ),
              ),
              const Spacer(),
              if (isToday)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: event.color,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Text(
                    '今天',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            event.title,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: isDark ? Colors.white : Colors.black87,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const Spacer(),
          Text(
            timeLabel,
            style: TextStyle(
              fontSize: 12,
              color: isPast
                  ? (isDark ? Colors.white30 : Colors.grey[400])
                  : event.color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContentView(bool isDark, Color primaryColor) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: GlassContainer(
          padding: const EdgeInsets.all(32),
          borderRadius: 24,
          blur: 16,
          opacity: 0.3,
          backgroundColor:
              isDark ? const Color(0xFF1A1A2E) : Colors.white,
          borderColor: isDark
              ? Colors.white.withValues(alpha: 0.08)
              : Colors.black.withValues(alpha: 0.06),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  color: primaryColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Icon(
                  Icons.calendar_month_outlined,
                  size: 40,
                  color: primaryColor,
                ),
              ),
              const SizedBox(height: 24),
              Text(
                '校历',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: isDark ? Colors.white : Colors.black87,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '请将校历图片放置在',
                style: TextStyle(
                  fontSize: 14,
                  color: isDark ? Colors.white54 : Colors.grey[600],
                ),
              ),
              const SizedBox(height: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.08)
                      : Colors.black.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'assets/images/xiaoli.jpg',
                  style: TextStyle(
                    fontSize: 13,
                    fontFamily: 'monospace',
                    color: isDark ? Colors.white70 : Colors.black54,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  bool _isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }
}

class _CalendarEvent {
  final String title;
  final DateTime date;
  final Color color;
  final IconData icon;

  _CalendarEvent({
    required this.title,
    required this.date,
    required this.color,
    required this.icon,
  });
}
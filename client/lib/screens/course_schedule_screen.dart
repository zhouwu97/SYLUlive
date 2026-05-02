import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/auth_provider.dart';
import '../providers/edu_provider.dart';
import '../providers/course_schedule_provider.dart';
import '../widgets/glass_container.dart';
import '../main.dart' show navigatorKey;
import 'edu_screen.dart';

/// 每节课槽的高度
const double slotHeight = 85.0;

/// 左侧时间轴宽度（必须与表头左侧留空一致）
const double timeColumnWidth = 35.0;

/// 颜色池（5色，确保各不相同）
const List<Color> courseColors = [
  Color(0xFF448AFF), // 蓝
  Color(0xFF00C853), // 绿
  Color(0xFF9C27B0), // 紫
  Color(0xFFFF5252), // 红
  Color(0xFFFF9800), // 橙
];

/// 根据课程名哈希计算颜色索引（不同课程不同颜色，非随机）
/// 空名称时 fallback 到 courseCode + location 做区分
int getCourseColorIndex(String name, {String? courseCode, String? location}) {
  String input = name;
  if (name.isEmpty) {
    input = '${courseCode ?? ''}_${location ?? ''}';
  }
  if (input.isEmpty) return 0;
  int hash = 0;
  for (int i = 0; i < input.length; i++) {
    hash += input.codeUnitAt(i);
  }
  return hash % courseColors.length;
}

/// 获取课程卡片颜色
Color getCourseColor(String name, {bool isActive = true, String? courseCode, String? location}) {
  final idx = getCourseColorIndex(name, courseCode: courseCode, location: location);
  final base = courseColors[idx];
  return isActive ? base.withOpacity(0.55) : Colors.grey.withOpacity(0.4);
}

/// 星期标签
const _wd = ['一', '二', '三', '四', '五', '六', '日'];

/// 每节课开始时间
const _starts = ['08:00', '08:55', '10:00', '10:55', '14:00', '14:55', '16:00', '16:55', '19:00', '19:55', '20:50', '21:45'];

/// 每节课结束时间
const _ends = ['08:45', '09:40', '10:45', '11:40', '14:45', '15:40', '16:45', '17:40', '19:45', '20:40', '21:35', '22:30'];

/// 格式化月/日
String _md(DateTime d) => '${d.month}/${d.day}';

class CourseScheduleScreen extends StatefulWidget {
  const CourseScheduleScreen({super.key});

  @override
  State<CourseScheduleScreen> createState() => _CourseScheduleScreenState();
}

class _CourseScheduleScreenState extends State<CourseScheduleScreen> {
  late DateTime _weekStart;
  bool _didLoad = false;
  bool _initializing = true;
  double _cardOpacity = 0.4;

  // 左右滑动切周
  late PageController _weekPageController;

  static DateTime _mondayOf(DateTime d) {
    return DateTime(d.year, d.month, d.day).subtract(Duration(days: d.weekday - 1));
  }

  @override
  void initState() {
    super.initState();
    _weekStart = _mondayOf(DateTime.now());
    _weekPageController = PageController(initialPage: 500);
    _loadSettings();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final auth = context.read<AuthProvider>();
      if (auth.user == null) return;
      final uid = auth.user!.id.toString();
      context.read<EduProvider>().setUserId(uid);
      context.read<CourseScheduleProvider>().setUserId(uid);
    });
  }

  @override
  void dispose() {
    _weekPageController.dispose();
    super.dispose();
  }

  void _autoLoad(EduProvider edu, CourseScheduleProvider sc) {
    if (_didLoad) return;
    // 状态还没加载完，继续等
    if (_initializing && !edu.isBound) return;
    // 已确认未绑定
    if (!edu.isBound) {
      _initializing = false;
      return;
    }
    if (sc.isLoading) return;
    _didLoad = true;
    _initializing = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (edu.isBound) sc.loadCourses();
    });
  }

  // PageView 滑动切换周
  void _onWeekPageChanged(int index) {
    // 以当前周为基准，向前向后推算
    final now = DateTime.now();
    final currentMonday = _mondayOf(now);
    final targetMonday = currentMonday.add(Duration(days: (index - 500) * 7));
    setState(() => _weekStart = targetMonday);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Consumer2<EduProvider, CourseScheduleProvider>(
          builder: (context, edu, sc, _) {
            _autoLoad(edu, sc);

            // 启动中 — 等待状态加载，避免闪现绑定页
            if (_initializing) {
              return const Center(child: CircularProgressIndicator());
            }

            // 未绑定教务账号
            if (!edu.isBound) {
              return _buildBindView(context, edu, sc, isDark);
            }

            // 加载中且无数据
            if (sc.isLoading && sc.courses.isEmpty) {
              return const Center(child: CircularProgressIndicator());
            }

            // 主界面：表头 + PageView 横向滑动切周
            return Column(
              children: [
                _buildDateHeader(sc),
                Expanded(
                  child: sc.courses.isEmpty
                      ? _buildEmptyView(context, isDark)
                      : SingleChildScrollView(
                          child: _buildCourseGridForWeek(sc, _weekStart),
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  // ====== 顶部表头 ======
  Widget _buildDateHeader(CourseScheduleProvider sc) {
    final today = DateTime.now();
    final todayDate = DateTime(today.year, today.month, today.day);
    final academicWeek = sc.getAcademicWeek(_weekStart);

    return Container(
      color: Colors.transparent,
      child: Column(
        children: [
          // 标题栏：大字号周次 + 日期 + 右侧图标
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 16, 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      GestureDetector(
                        onTap: () => _pickSemesterStart(context),
                        child: Text(
                          academicWeek != null ? '第 $academicWeek 周' : '设置学期',
                          style: const TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.w900, height: 1.1),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${_weekStart.year}/${_weekStart.month}/${_weekStart.day} 周${_wd[_weekStart.weekday - 1]}',
                        style: const TextStyle(color: Colors.white70, fontSize: 18),
                      ),
                    ],
                  ),
                ),
                Row(
                  children: [
                    IconButton(icon: const Icon(Icons.file_download_outlined, size: 22), color: Colors.white, onPressed: () {}, tooltip: '导出'),
                    IconButton(icon: const Icon(Icons.share_outlined, size: 22), color: Colors.white, onPressed: () {}, tooltip: '分享'),
                    IconButton(icon: const Icon(Icons.settings_outlined, size: 22), color: Colors.white, onPressed: () => _showOpacitySheet(context), tooltip: '设置'),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // 星期表头
          Row(
            children: [
              SizedBox(width: timeColumnWidth),
              ...List.generate(7, (i) {
                final d = _weekStart.add(Duration(days: i));
                final isToday = d == todayDate;
                return Expanded(
                  child: Column(
                    children: [
                      Text(_wd[i], style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 2),
                      Text(_md(d), style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: isToday ? FontWeight.w600 : FontWeight.w400)),
                    ],
                  ),
                );
              }),
            ],
          ),
        ],
      ),
    );
  }

  // ====== 绑定视图 ======
  Widget _buildBindView(BuildContext context, EduProvider edu, CourseScheduleProvider sc, bool isDark) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: GlassContainer(
          padding: const EdgeInsets.all(32),
          borderRadius: 20,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.school, size: 72, color: Theme.of(context).primaryColor.withValues(alpha: 0.7)),
              const SizedBox(height: 20),
              const Text('绑定教务账号', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              Text(
                '绑定后可查看课表、成绩等信息',
                style: TextStyle(fontSize: 15, color: isDark ? Colors.grey[400] : Colors.grey[600]),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 28),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () => _showBindDialog(context, edu, sc),
                  icon: const Icon(Icons.link),
                  label: const Text('立即绑定', style: TextStyle(fontSize: 16)),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showBindDialog(BuildContext context, EduProvider edu, CourseScheduleProvider sc) {
    final sidCtrl = TextEditingController();
    final pwdCtrl = TextEditingController();
    bool isLoading = false;

    showDialog(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('绑定教务账号'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: sidCtrl,
                decoration: const InputDecoration(labelText: '教务学号', hintText: '请输入10位学号'),
                maxLength: 10,
                enabled: !isLoading,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: pwdCtrl,
                decoration: const InputDecoration(labelText: '教务密码'),
                obscureText: true,
                enabled: !isLoading,
              ),
              if (isLoading)
                const Padding(
                  padding: EdgeInsets.only(top: 20),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                      SizedBox(width: 12),
                      Text('正在连接教务系统...', style: TextStyle(color: Colors.grey)),
                    ],
                  ),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: isLoading ? null : () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: isLoading
                  ? null
                  : () async {
                      setDialogState(() => isLoading = true);
                      final ok = await edu.bind(sidCtrl.text, pwdCtrl.text);
                      if (ctx.mounted) Navigator.pop(ctx);
                      if (ok && context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('绑定成功')));
                        _didLoad = false;
                        sc.loadCourses(forceRefresh: true);
                      } else if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(edu.errorMessage ?? '绑定失败')));
                      }
                    },
              child: isLoading
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Text('绑定'),
            ),
          ],
        ),
      ),
    );
  }

  // ====== 空状态视图 ======
  Widget _buildEmptyView(BuildContext context, bool isDark) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: GlassContainer(
          padding: const EdgeInsets.all(32),
          borderRadius: 20,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.event_busy, size: 64, color: isDark ? Colors.grey[600] : Colors.grey[400]),
              const SizedBox(height: 16),
              const Text('暂无课表数据', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text(
                '请先到教务管理获取课表',
                style: TextStyle(fontSize: 14, color: isDark ? Colors.grey[400] : Colors.grey[600]),
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: () => _openEduManage(context),
                icon: const Icon(Icons.download),
                label: const Text('获取课表'),
                style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openEduManage(BuildContext context) async {
    _didLoad = true;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const EduScreen()));
    if (mounted) {
      context.read<CourseScheduleProvider>().loadCourses(forceRefresh: true);
    }
  }

  // ====== 透明度设置 ======
  static const _opacityKey = 'card_opacity';

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() => _cardOpacity = prefs.getDouble(_opacityKey) ?? 0.55);
  }

  Future<void> _saveOpacity(double v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_opacityKey, v);
  }

  void _showOpacitySheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey[400], borderRadius: BorderRadius.circular(2))),
              const SizedBox(height: 20),
              const Text('调节卡片透明度', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              Row(children: [
                const Text('透明', style: TextStyle(fontSize: 13, color: Colors.grey)),
                Expanded(
                  child: Slider(
                    value: _cardOpacity,
                    min: 0.1, max: 1.0,
                    divisions: 18,
                    label: '${(_cardOpacity * 100).round()}%',
                    onChanged: (v) {
                      setSheetState(() {});
                      setState(() => _cardOpacity = v);
                      _saveOpacity(v);
                    },
                  ),
                ),
                const Text('实色', style: TextStyle(fontSize: 13, color: Colors.grey)),
              ]),
              Text('${(_cardOpacity * 100).round()}%', style: TextStyle(fontSize: 14, color: Theme.of(context).primaryColor, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickSemesterStart(BuildContext context) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: context.read<CourseScheduleProvider>().semesterStart ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
      helpText: '选择本学期第一周的星期一',
    );
    if (picked != null) {
      await context.read<CourseScheduleProvider>().setSemesterStart(picked);
      if (mounted) setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已设置开学日期：${picked.year}-${picked.month}-${picked.day}')),
      );
    }
  }

  // ====== 课程网格（指定某一周） ======
  Widget _buildCourseGridForWeek(CourseScheduleProvider sc, DateTime weekStart) {
    final wn = sc.getAcademicWeek(weekStart);
    final totalH = 12 * slotHeight;
    final screenW = MediaQuery.of(context).size.width;
    final exactW = (screenW - timeColumnWidth) / 7;

    final allActive = <CourseBlock>[];
    final allInactive = <CourseBlock>[];
    for (final c in sc.courses) {
      if (wn == null || c.weeks.isEmpty || c.weeks.contains(wn)) {
        allActive.add(c);
      } else {
        allInactive.add(c);
      }
    }

    return SingleChildScrollView(
      child: SizedBox(
        height: totalH,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // 左侧时间轴
            Positioned(
              left: 0, top: 0, bottom: 0,
              width: timeColumnWidth,
              child: Column(
                children: List.generate(12, (i) => Container(
                  height: slotHeight,
                  alignment: Alignment.center,
                  child: Text('${i + 1}\n${_starts[i]}\n${_ends[i]}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 11, color: Color(0xFF888888), height: 1.3)),
                )),
              ),
            ),
            // 网格线（7 天 × 12 节）
            for (int d = 0; d < 7; d++)
              Positioned(
                left: timeColumnWidth + d * exactW,
                top: 0, bottom: 0,
                width: exactW,
                child: Column(
                  children: List.generate(12, (i) => Container(
                    height: slotHeight,
                    decoration: BoxDecoration(
                      border: Border(
                        left: BorderSide(color: Colors.black.withOpacity(0.08), width: 0.5),
                        bottom: BorderSide(color: Colors.white.withValues(alpha: 0.2), width: 0.5),
                      ),
                    ),
                  )),
                ),
              ),
            // 课程卡片
            for (final c in allInactive) _buildCard(c, false, exactW),
            for (final c in allActive) _buildCard(c, true, exactW),
          ],
        ),
      ),
    );
  }

  // ====== 课程卡片 ======
  Widget _buildCard(CourseBlock c, bool isActive, double exactW) {
    final top = (c.startSection - 1) * slotHeight;
    final h = c.span * slotHeight - 4;
    final base = getCourseColor(c.name, isActive: isActive, courseCode: c.courseCode, location: c.location)
        .withValues(alpha: isActive ? _cardOpacity : 0.3);

    return Positioned(
      left: timeColumnWidth + (c.weekday - 1) * exactW + 1,
      width: exactW - 2,
      top: top,
      height: h,
      child: GestureDetector(
        onTap: () => _showDetail(c),
        child: Container(
          alignment: Alignment.topLeft,
          padding: const EdgeInsets.all(4.0),
          decoration: BoxDecoration(
            color: base,
            borderRadius: BorderRadius.circular(12.0),
            border: Border.all(color: Colors.white.withValues(alpha: 0.5), width: 0.8),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!isActive)
                const Text('[非本周]', style: TextStyle(fontSize: 8, fontWeight: FontWeight.w700, color: Colors.white54)),
              Text(
                c.name.isNotEmpty ? c.name : '未知课名',
                style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold, height: 1.15),
                textAlign: TextAlign.left,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
              ),
              if (c.location != null && c.location!.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  '@${c.location}',
                  style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600, height: 1.15),
                  textAlign: TextAlign.left,
                ),
              ],
              if (c.teacher != null && c.teacher!.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  c.teacher!,
                  style: const TextStyle(color: Colors.white60, fontSize: 10),
                  textAlign: TextAlign.left,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ====== 课程详情 ======
  void _showDetail(CourseBlock c) {
    final color = courseColors[getCourseColorIndex(c.name)];
    final wdn = _wd[c.weekday - 1];

    showModalBottomSheet(
      context: navigatorKey.currentContext!,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40, height: 4,
                decoration: BoxDecoration(color: Colors.grey[400], borderRadius: BorderRadius.circular(2)),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Container(width: 4, height: 28, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
                const SizedBox(width: 12),
                Expanded(child: Text(c.name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold))),
              ],
            ),
            const SizedBox(height: 20),
            _detailRow(Icons.person_outline, '教师', c.teacher ?? '未知'),
            _detailRow(Icons.location_on_outlined, '教室', c.location ?? '未知'),
            _detailRow(Icons.access_time, '时间', '周$wdn 第${c.startSection}-${c.endSection}节'),
            _detailRow(Icons.date_range, '周次', c.weeks.isNotEmpty ? '第${c.weeks.first}-${c.weeks.last}周' : '未知'),
            if (c.note != null && c.note!.isNotEmpty) _detailRow(Icons.note_outlined, '备注', c.note!),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _detailRow(IconData icon, String l, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Icon(icon, size: 20, color: Colors.grey[600]),
            const SizedBox(width: 12),
            Text('$l：', style: TextStyle(fontSize: 14, color: Colors.grey[600])),
            Expanded(child: Text(v, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500))),
          ],
        ),
      );
}
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/teacher_provider.dart';
import '../providers/major_provider.dart';
import '../models/teacher.dart';
import 'teacher_detail_screen.dart';
import 'major_detail_screen.dart';

class TeacherRateScreen extends StatefulWidget {
  const TeacherRateScreen({super.key});
  @override
  State<TeacherRateScreen> createState() => _TeacherRateScreenState();
}

class _TeacherRateScreenState extends State<TeacherRateScreen> with SingleTickerProviderStateMixin {
  late TabController _tabCtrl;
  final _searchCtrl = TextEditingController();
  bool _showDisclaimer = true;

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 2, vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<TeacherProvider>().loadTeachers();
      context.read<MajorProvider>().loadMajors();
    });
  }

  @override
  void dispose() {
    _tabCtrl.dispose(); _searchCtrl.dispose(); super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('榜单'),
        backgroundColor: Colors.transparent, elevation: 0,
        bottom: TabBar(
          controller: _tabCtrl, labelStyle: const TextStyle(fontWeight: FontWeight.bold),
          tabs: const [Tab(text: '教师榜'), Tab(text: '专业榜')],
        ),
        actions: [
          IconButton(icon: const Icon(Icons.add_circle_outline), tooltip: '添加', onPressed: _showAddDialog),
        ],
      ),
      body: Column(children: [
        if (_showDisclaimer) _buildDisclaimer(isDark),
        _buildSearchBar(isDark),
        Expanded(child: TabBarView(controller: _tabCtrl, children: [
          _buildTeacherList(isDark),
          _buildMajorList(isDark),
        ])),
      ]),
    );
  }

  Widget _buildDisclaimer(bool isDark) => Container(
    margin: const EdgeInsets.fromLTRB(12, 8, 12, 0), padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(color: isDark ? Colors.blueGrey[900]!.withValues(alpha: 0.6) : Colors.blue[50], borderRadius: BorderRadius.circular(12)),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(Icons.info_outline, size: 20, color: isDark ? Colors.blue[300] : Colors.blue[700]), const SizedBox(width: 8),
      Expanded(child: Text('本版块仅用于介绍给自己上过课的老师或就读专业，严禁侮辱。违规者一次禁言一周，第二次一个月，第三次永久禁言。本人对此表达严正声明。', style: TextStyle(fontSize: 12, color: isDark ? Colors.grey[300] : Colors.grey[700], height: 1.4))),
      GestureDetector(onTap: () => setState(() => _showDisclaimer = false), child: Icon(Icons.close, size: 16, color: Colors.grey)),
    ]),
  );

  Widget _buildSearchBar(bool isDark) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
    child: TextField(
      controller: _searchCtrl,
      decoration: InputDecoration(hintText: '搜索...', prefixIcon: const Icon(Icons.search, size: 20), filled: true, fillColor: isDark ? Colors.white10 : Colors.grey[100], border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none), contentPadding: const EdgeInsets.symmetric(vertical: 10)),
      onChanged: (v) {
        if (_tabCtrl.index == 0) context.read<TeacherProvider>().loadTeachers(query: v);
      },
    ),
  );

  Widget _buildTeacherList(bool isDark) => Consumer<TeacherProvider>(builder: (_, t, __) {
    if (t.isLoading && t.teachers.isEmpty) return const Center(child: CircularProgressIndicator());
    if (t.teachers.isEmpty) return Center(child: Text('暂无教师', style: TextStyle(color: isDark ? Colors.white54 : Colors.grey[600])));
    return ListView.builder(padding: const EdgeInsets.fromLTRB(12, 4, 12, 80), itemCount: t.teachers.length, itemBuilder: (_, i) {
      final item = t.teachers[i];
      return _buildCard(item.name, item.course, item.averageStar, item.ratingCount, isDark, () {
        Navigator.push(context, MaterialPageRoute(builder: (_) => TeacherDetailScreen(teacherId: item.id, teacherName: item.name)));
      });
    });
  });

  Widget _buildMajorList(bool isDark) => Consumer<MajorProvider>(builder: (_, m, __) {
    if (m.isLoading && m.majors.isEmpty) return const Center(child: CircularProgressIndicator());
    if (m.majors.isEmpty) return Center(child: Text('暂无专业', style: TextStyle(color: isDark ? Colors.white54 : Colors.grey[600])));
    return ListView.builder(padding: const EdgeInsets.fromLTRB(12, 4, 12, 80), itemCount: m.majors.length, itemBuilder: (_, i) {
      final item = m.majors[i];
      return _buildCard(item.name, item.level, item.averageStar, item.ratingCount, isDark, () {
        Navigator.push(context, MaterialPageRoute(builder: (_) => MajorDetailScreen(majorId: item.id, majorName: item.name)));
      });
    });
  });

  Widget _buildCard(String title, String subtitle, double star, int count, bool isDark, VoidCallback onTap) => Card(
    margin: const EdgeInsets.symmetric(vertical: 4), color: isDark ? Colors.grey[850] : Colors.white,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    child: InkWell(borderRadius: BorderRadius.circular(12), onTap: onTap,
      child: Padding(padding: const EdgeInsets.all(14), child: Row(children: [
        CircleAvatar(radius: 22, backgroundColor: _avatarColor(title, isDark), child: Text(title[0], style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold))),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          Text(subtitle, style: TextStyle(fontSize: 13, color: isDark ? Colors.grey[400] : Colors.grey[600])),
          const SizedBox(height: 4),
          Row(children: [Row(mainAxisSize: MainAxisSize.min, children: List.generate(5, (i) => Icon(i < star.round() ? Icons.star : Icons.star_border, size: 15, color: i < star.round() ? Colors.amber : Colors.grey[400]))), const SizedBox(width: 6), Text('${star.toStringAsFixed(1)} ($count人)', style: TextStyle(fontSize: 12, color: Colors.grey))]),
        ])),
        const Icon(Icons.chevron_right, color: Colors.grey),
      ])),
    ),
  );

  Color _avatarColor(String n, bool isDark) => const [Color(0xFF6366F1), Color(0xFF8B5CF6), Color(0xFFEC4899), Color(0xFF06B6D4)][n.hashCode.abs() % 4];

  void _showAddDialog() {
    final nameCtrl = TextEditingController(), courseCtrl = TextEditingController(), levelCtrl = TextEditingController(text: '本科');
    final isTeacher = _tabCtrl.index == 0;
    showDialog(context: context, builder: (ctx) => AlertDialog(
      title: Text(isTeacher ? '添加老师' : '添加专业'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: nameCtrl, decoration: InputDecoration(labelText: isTeacher ? '姓名' : '专业名')),
        const SizedBox(height: 8),
        if (isTeacher) TextField(controller: courseCtrl, decoration: const InputDecoration(labelText: '课程'))
        else DropdownButtonFormField(value: '本科', items: const [DropdownMenuItem(value: '本科', child: Text('本科')), DropdownMenuItem(value: '研究生', child: Text('研究生'))], onChanged: (v) => levelCtrl.text = v!),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        ElevatedButton(onPressed: () async {
          Navigator.pop(ctx);
          if (isTeacher) await context.read<TeacherProvider>().addTeacher(nameCtrl.text, courseCtrl.text);
          else await context.read<MajorProvider>().addMajor(nameCtrl.text, levelCtrl.text);
        }, child: const Text('提交')),
      ],
    ));
  }
}

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/teacher_provider.dart';
import '../models/teacher.dart';
import 'teacher_detail_screen.dart';

class TeacherRateScreen extends StatefulWidget {
  const TeacherRateScreen({super.key});

  @override
  State<TeacherRateScreen> createState() => _TeacherRateScreenState();
}

class _TeacherRateScreenState extends State<TeacherRateScreen> {
  final _searchController = TextEditingController();
  bool _showDisclaimer = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<TeacherProvider>().loadTeachers();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('课程性格符合榜'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.add_circle_outline),
            tooltip: '添加老师',
            onPressed: () => _showAddTeacherDialog(context),
          ),
        ],
      ),
      body: Consumer<TeacherProvider>(
        builder: (context, provider, _) {
          return Column(
            children: [
              // 免责声明
              if (_showDisclaimer) _buildDisclaimer(isDark),
              // 搜索栏
              _buildSearchBar(isDark),
              // 列表
              Expanded(child: provider.isLoading && provider.teachers.isEmpty
                  ? const Center(child: CircularProgressIndicator())
                  : provider.teachers.isEmpty
                      ? _buildEmptyView(isDark)
                      : _buildTeacherList(provider, isDark)),
            ],
          );
        },
      ),
    );
  }

  Widget _buildDisclaimer(bool isDark) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? Colors.blueGrey[900]!.withValues(alpha: 0.6) : Colors.blue[50],
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: isDark ? Colors.blueGrey[700]! : Colors.blue[100]!),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 20, color: isDark ? Colors.blue[300] : Colors.blue[700]),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '本版块仅用于介绍给自己上过课的老师，不对其劳动成果进行评价，不对其人格进行贬低，只谈论老师与自己的性格差异或课堂习惯。严禁对老师进行侮辱，本人对此表达严正声明。违规者一次禁言一周，第二次禁言一个月，第三次则永久不能在此版块发言。',
              style: TextStyle(fontSize: 12, color: isDark ? Colors.grey[300] : Colors.grey[700], height: 1.4),
            ),
          ),
          GestureDetector(
            onTap: () => setState(() => _showDisclaimer = false),
            child: Icon(Icons.close, size: 16, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar(bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: TextField(
        controller: _searchController,
        decoration: InputDecoration(
          hintText: '搜索老师名字...',
          prefixIcon: const Icon(Icons.search, size: 20),
          suffixIcon: _searchController.text.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.clear, size: 18),
                  onPressed: () {
                    _searchController.clear();
                    context.read<TeacherProvider>().loadTeachers();
                    setState(() {});
                  },
                )
              : null,
          filled: true,
          fillColor: isDark ? Colors.white10 : Colors.grey[100],
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
        ),
        onChanged: (v) {
          setState(() {});
          context.read<TeacherProvider>().loadTeachers(query: v);
        },
      ),
    );
  }

  Widget _buildEmptyView(bool isDark) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.people_outline, size: 64, color: isDark ? Colors.grey[600] : Colors.grey[400]),
          const SizedBox(height: 12),
          Text('暂无老师', style: TextStyle(fontSize: 16, color: isDark ? Colors.grey[400] : Colors.grey[600])),
          const SizedBox(height: 4),
          Text('点击右上角 + 添加', style: TextStyle(fontSize: 13, color: Colors.grey)),
        ],
      ),
    );
  }

  Widget _buildTeacherList(TeacherProvider provider, bool isDark) {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 80),
      itemCount: provider.teachers.length,
      itemBuilder: (ctx, i) {
        final t = provider.teachers[i];
        return _buildTeacherCard(t, isDark);
      },
    );
  }

  Widget _buildTeacherCard(Teacher t, bool isDark) {
    final stars = _buildStarRow(t.averageStar, isDark);

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      color: isDark ? Colors.grey[850] : Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          Navigator.push(context, MaterialPageRoute(
            builder: (_) => TeacherDetailScreen(teacherId: t.id, teacherName: t.name),
          )).then((_) {
            context.read<TeacherProvider>().loadTeachers();
          });
        },
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              // 头像
              CircleAvatar(
                radius: 22,
                backgroundColor: _getAvatarColor(t.name, isDark),
                child: Text(t.name.isNotEmpty ? t.name[0] : '?',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(t.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(t.course, style: TextStyle(fontSize: 13, color: isDark ? Colors.grey[400] : Colors.grey[600])),
                    const SizedBox(height: 4),
                    Row(children: [
                      stars,
                      const SizedBox(width: 6),
                      Text('${t.averageStar.toStringAsFixed(1)} (${t.ratingCount}人)',
                          style: TextStyle(fontSize: 12, color: Colors.grey)),
                    ]),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: Colors.grey),
            ],
          ),
        ),
      ),
    );
  }

  Color _getAvatarColor(String name, bool isDark) {
    final colors = [
      const Color(0xFF6366F1), const Color(0xFF8B5CF6), const Color(0xFFEC4899),
      const Color(0xFF06B6D4), const Color(0xFFF59E0B), const Color(0xFF10B981),
    ];
    return colors[name.hashCode.abs() % colors.length];
  }

  Widget _buildStarRow(double avg, bool isDark) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(5, (i) {
        return Icon(
          i < avg.round() ? Icons.star : Icons.star_border,
          size: 15,
          color: i < avg.round() ? Colors.amber : (isDark ? Colors.grey[700] : Colors.grey[300]),
        );
      }),
    );
  }

  void _showAddTeacherDialog(BuildContext context) {
    final nameCtrl = TextEditingController();
    final courseCtrl = TextEditingController();
    final formKey = GlobalKey<FormState>();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加老师'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: nameCtrl,
                decoration: const InputDecoration(labelText: '老师姓名', prefixIcon: Icon(Icons.person)),
                validator: (v) => (v == null || v.isEmpty) ? '请输入姓名' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: courseCtrl,
                decoration: const InputDecoration(labelText: '所教课程', prefixIcon: Icon(Icons.book)),
                validator: (v) => (v == null || v.isEmpty) ? '请输入课程' : null,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          ElevatedButton(
            onPressed: () async {
              if (formKey.currentState!.validate()) {
                final ok = await context.read<TeacherProvider>().addTeacher(nameCtrl.text, courseCtrl.text);
                if (ctx.mounted) Navigator.pop(ctx);
                if (ok && mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('添加成功'), backgroundColor: Colors.green),
                  );
                }
              }
            },
            child: const Text('添加'),
          ),
        ],
      ),
    );
  }
}

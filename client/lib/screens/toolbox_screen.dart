import 'package:flutter/material.dart';
import '../widgets/glass_container.dart';
import 'erke_score_screen.dart';

class ToolboxScreen extends StatelessWidget {
  const ToolboxScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: isDark 
            ? [const Color(0xFF131720), const Color(0xFF1A2235)]
            : [const Color(0xFFF4F6FB), const Color(0xFFE8ECF4)],
        ),
      ),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: const Text('工具箱'),
          backgroundColor: Colors.transparent,
          elevation: 0,
        ),
        body: GridView.count(
          padding: EdgeInsets.fromLTRB(20, MediaQuery.of(context).padding.top + kToolbarHeight + 20, 20, 20),
          crossAxisCount: 2,
          mainAxisSpacing: 16,
          crossAxisSpacing: 16,
          children: [
            _buildToolCard(
              context,
              icon: Icons.school_outlined,
              color: Colors.green,
              title: '二课分查询',
              subtitle: '支持 WebVPN 穿透',
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ErkeScoreScreen())),
            ),
            _buildToolCard(
              context,
              icon: Icons.auto_stories_outlined,
              color: Colors.blue,
              title: '更多工具',
              subtitle: '敬请期待',
              onTap: () {},
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildToolCard(BuildContext context, {
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    return GestureDetector(
      onTap: onTap,
      child: GlassContainer(
        padding: const EdgeInsets.all(20),
        borderRadius: 24,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: color.withOpacity(0.12),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(icon, color: color, size: 32),
            ),
            const SizedBox(height: 12),
            Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 4),
            Text(subtitle, textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: isDark ? Colors.white54 : Colors.grey[600])),
          ],
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/water_section_provider.dart';
import '../models/water_section.dart';
import '../widgets/water_section/section_avatar.dart';
import 'water_section_manage_screen.dart';

class AdminWaterSectionsScreen extends StatefulWidget {
  const AdminWaterSectionsScreen({super.key});

  @override
  State<AdminWaterSectionsScreen> createState() =>
      _AdminWaterSectionsScreenState();
}

class _AdminWaterSectionsScreenState extends State<AdminWaterSectionsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<WaterSectionProvider>().loadSections();
    });
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<WaterSectionProvider>();
    final sections = provider.activeSections;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: const Text('水帖版块管理'),
      ),
      body: provider.isLoading && sections.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: sections.length,
              itemBuilder: (context, index) {
                final section = sections[index];
                return Card(
                  margin: const EdgeInsets.only(bottom: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  color: isDark ? Colors.grey[850] : Colors.white,
                  child: ListTile(
                    contentPadding: const EdgeInsets.all(16),
                    leading: SectionAvatar(
                      section: section,
                      size: 40,
                      radius: 20,
                      isDark: isDark,
                      showBorder: true,
                    ),
                    title: Text(
                      section.title,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 4),
                        Text(section.subtitle.isNotEmpty
                            ? section.subtitle
                            : '暂无描述'),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            _buildBadge('标签: ${section.tags.length}',
                                Colors.blue, isDark),
                            const SizedBox(width: 8),
                            _buildBadge('敏感度: ${section.sensitiveLevel}',
                                Colors.orange, isDark),
                          ],
                        ),
                      ],
                    ),
                    trailing: ElevatedButton(
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) =>
                                WaterSectionManageScreen(section: section),
                          ),
                        );
                      },
                      style: ElevatedButton.styleFrom(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      child: const Text('管理'),
                    ),
                  ),
                );
              },
            ),
    );
  }

  Widget _buildBadge(String text, Color color, bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          color: isDark ? color.withOpacity(0.9) : color,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

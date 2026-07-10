import 'package:flutter/material.dart';
import '../campus/campus_theme.dart';
import '../../models/course_term.dart';

class CourseTermSwitchSheet extends StatefulWidget {
  final CourseTerm currentTerm;
  final int enrollmentYear;

  const CourseTermSwitchSheet({
    super.key,
    required this.currentTerm,
    required this.enrollmentYear,
  });

  static Future<CourseTerm?> show(
    BuildContext context, {
    required CourseTerm currentTerm,
    required int enrollmentYear,
  }) {
    return showModalBottomSheet<CourseTerm>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => CourseTermSwitchSheet(
        currentTerm: currentTerm,
        enrollmentYear: enrollmentYear,
      ),
    );
  }

  @override
  State<CourseTermSwitchSheet> createState() => _CourseTermSwitchSheetState();
}

class _CourseTermSwitchSheetState extends State<CourseTermSwitchSheet> {
  late List<CourseTerm> _terms;
  late String _selectedYear;
  late int _selectedSemester;

  @override
  void initState() {
    super.initState();
    _terms = CourseTermCatalog.generate(enrollmentYear: widget.enrollmentYear);
    _selectedYear = widget.currentTerm.year;
    _selectedSemester = widget.currentTerm.semester;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      decoration: BoxDecoration(
        color: isDark ? CampusTheme.darkBg : CampusTheme.bg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              margin: const EdgeInsets.symmetric(vertical: 12),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: isDark ? Colors.white24 : Colors.black12,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
              child: Row(
                children: [
                  Text(
                    '切换学期',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: isDark ? Colors.white : CampusTheme.text,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 300,
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: _terms.length,
                itemBuilder: (context, index) {
                  final term = _terms[index];
                  final isSelected = term.year == _selectedYear &&
                      term.semester == _selectedSemester;

                  return Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? CampusTheme.primary.withValues(alpha: 0.1)
                          : (isDark ? CampusTheme.darkCard : Colors.white),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: isSelected
                            ? CampusTheme.primary.withValues(alpha: 0.3)
                            : Colors.transparent,
                      ),
                    ),
                    child: ListTile(
                      onTap: () {
                        setState(() {
                          _selectedYear = term.year;
                          _selectedSemester = term.semester;
                        });
                      },
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16)),
                      title: Text(
                        term.title,
                        style: TextStyle(
                          color: isSelected
                              ? CampusTheme.primary
                              : (isDark ? Colors.white : CampusTheme.text),
                          fontWeight:
                              isSelected ? FontWeight.bold : FontWeight.w500,
                        ),
                      ),
                      trailing: isSelected
                          ? const Icon(Icons.check_circle_rounded,
                              color: CampusTheme.primary)
                          : null,
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(24),
              child: ElevatedButton(
                onPressed: () {
                  final term = _terms.firstWhere((t) =>
                      t.year == _selectedYear &&
                      t.semester == _selectedSemester);
                  Navigator.pop(context, term);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: CampusTheme.primary,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  minimumSize: const Size(double.infinity, 50),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: const Text(
                  '切换到该学期',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
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

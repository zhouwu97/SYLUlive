import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/widgets/exam_papers/exam_paper_toolbar.dart';

void main() {
  testWidgets('宽屏工具栏在同一行展示全部筛选项', (tester) async {
    final searchController = TextEditingController();
    addTearDown(searchController.dispose);

    await tester.pumpWidget(_buildToolbar(
      width: 780,
      searchController: searchController,
    ));

    final academicYear = find.text('全部学年');
    final semester = find.text('全部学期');
    final examType = find.text('全部类型');
    final sort = find.text('最新');
    final toolbar = find.byKey(const Key('toolbar-host'));
    final toolbarRect = tester.getRect(toolbar);
    final dropdowns = find.byType(DropdownButton<String>);
    final toolbarScrollables = tester.widgetList<Scrollable>(
      find.descendant(
        of: toolbar,
        matching: find.byType(Scrollable),
      ),
    );
    final searchInputScrollables = tester
        .widgetList<Scrollable>(
          find.descendant(
            of: find.descendant(
              of: toolbar,
              matching: find.byType(TextField),
            ),
            matching: find.byType(Scrollable),
          ),
        )
        .toSet();
    final filterScrollables = toolbarScrollables.where(
      (scrollable) => !searchInputScrollables.contains(scrollable),
    );

    expect(academicYear, findsOneWidget);
    expect(semester, findsOneWidget);
    expect(examType, findsOneWidget);
    expect(sort, findsOneWidget);
    expect(dropdowns, findsNWidgets(4));
    final dropdownRects = List.generate(
      4,
      (index) => tester.getRect(dropdowns.at(index)),
    );

    for (final dropdownRect in dropdownRects) {
      expect(dropdownRect.left, greaterThanOrEqualTo(toolbarRect.left));
      expect(dropdownRect.right, lessThanOrEqualTo(toolbarRect.right));
      expect(dropdownRect.top, greaterThanOrEqualTo(toolbarRect.top));
      expect(dropdownRect.bottom, lessThanOrEqualTo(toolbarRect.bottom));
    }

    for (final dropdownRect in dropdownRects.skip(1)) {
      expect(dropdownRect.top, closeTo(dropdownRects.first.top, 0.5));
    }
    expect(
      filterScrollables.where(
        (scrollable) =>
            scrollable.axisDirection == AxisDirection.right ||
            scrollable.axisDirection == AxisDirection.left,
      ),
      isEmpty,
    );
  });

  testWidgets('宽屏工具栏完整展示下载最多排序选项', (tester) async {
    final searchController = TextEditingController();
    addTearDown(searchController.dispose);

    await tester.pumpWidget(_buildToolbar(
      width: 780,
      sort: 'downloads',
      searchController: searchController,
    ));

    final sortLabel = find.text('下载最多');
    final dropdowns = find.byType(DropdownButton<String>);

    expect(sortLabel, findsOneWidget);
    expect(dropdowns, findsNWidgets(4));

    final sortDropdownRect = tester.getRect(dropdowns.at(3));
    final sortLabelRect = tester.getRect(sortLabel);
    expect(sortDropdownRect.width, greaterThanOrEqualTo(96));
    expect(
      sortLabelRect.left,
      greaterThanOrEqualTo(sortDropdownRect.left - 0.5),
    );
    expect(
      sortLabelRect.right,
      lessThanOrEqualTo(sortDropdownRect.right + 0.5),
    );
    expect(
      sortLabelRect.top,
      greaterThanOrEqualTo(sortDropdownRect.top - 0.5),
    );
    expect(
      sortLabelRect.bottom,
      lessThanOrEqualTo(sortDropdownRect.bottom + 0.5),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏工具栏将筛选项排列为两列两行', (tester) async {
    final searchController = TextEditingController();
    addTearDown(searchController.dispose);

    await tester.pumpWidget(_buildToolbar(
      width: 320,
      searchController: searchController,
    ));

    expect(find.text('全部学年'), findsOneWidget);
    expect(find.text('全部学期'), findsOneWidget);
    expect(find.text('全部类型'), findsOneWidget);
    expect(find.text('最新'), findsOneWidget);

    final dropdowns = find.byType(DropdownButton<String>);
    expect(dropdowns, findsNWidgets(4));
    final dropdownRects = List.generate(
      4,
      (index) => tester.getRect(dropdowns.at(index)),
    );

    expect(tester.takeException(), isNull);
    expect(dropdownRects[1].top, closeTo(dropdownRects[0].top, 0.5));
    expect(dropdownRects[2].top, greaterThan(dropdownRects[0].top));
    expect(dropdownRects[3].top, closeTo(dropdownRects[2].top, 0.5));
    expect(dropdownRects[0].left, lessThan(dropdownRects[1].left));
    expect(dropdownRects[0].right, lessThan(dropdownRects[1].right));
    expect(dropdownRects[2].left, lessThan(dropdownRects[3].left));
    expect(dropdownRects[2].right, lessThan(dropdownRects[3].right));
    expect(dropdownRects[2].left, closeTo(dropdownRects[0].left, 0.5));
    expect(dropdownRects[3].left, closeTo(dropdownRects[1].left, 0.5));
  });
}

Widget _buildToolbar({
  required double width,
  required TextEditingController searchController,
  String sort = 'latest',
}) {
  return ChangeNotifierProvider<ThemeProvider>(
    create: (_) => ThemeProvider(loadOnStart: false),
    child: MaterialApp(
      home: Scaffold(
        body: SizedBox(
          key: const Key('toolbar-host'),
          width: width,
          child: ExamPaperToolbar(
            searchController: searchController,
            onSearchChanged: (_) {},
            academicYear: '',
            semester: '',
            examType: '',
            sort: sort,
            academicYears: const ['2025-2026'],
            onAcademicYearChanged: (_) {},
            onSemesterChanged: (_) {},
            onExamTypeChanged: (_) {},
            onSortChanged: (_) {},
            total: 2,
            activeFilterCount: 0,
            onClearSearch: () {},
            onClearFilters: () {},
          ),
        ),
      ),
    ),
  );
}

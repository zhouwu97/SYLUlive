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

  testWidgets('窄屏工具栏将四个筛选项排列在同一行', (tester) async {
    final searchController = TextEditingController();
    addTearDown(searchController.dispose);

    await tester.pumpWidget(_buildToolbar(
      width: 320,
      searchController: searchController,
    ));

    final dropdowns = find.byType(DropdownButton<String>);
    expect(dropdowns, findsNWidgets(4));
    final dropdownRects = List.generate(
      4,
      (index) => tester.getRect(dropdowns.at(index)),
    );

    expect(tester.takeException(), isNull);
    for (final dropdownRect in dropdownRects.skip(1)) {
      expect(dropdownRect.top, closeTo(dropdownRects.first.top, 0.5));
    }
  });

  testWidgets('学年下拉展示服务端返回的全部学年并限制菜单高度', (tester) async {
    final searchController = TextEditingController();
    addTearDown(searchController.dispose);

    await tester.pumpWidget(_buildToolbar(
      width: 320,
      searchController: searchController,
      academicYears: const [
        '2025-2026',
        '2024-2025',
        '2023-2024',
        '2022-2023',
      ],
    ));

    final academicYearDropdown = tester.widget<DropdownButton<String>>(
      find.byType(DropdownButton<String>).first,
    );
    expect(
      academicYearDropdown.menuMaxHeight,
      kMinInteractiveDimension * 4,
    );

    await tester.tap(find.text('全部学年'));
    await tester.pumpAndSettle();
    expect(find.text('2025-2026'), findsOneWidget);
    expect(find.text('2024-2025'), findsOneWidget);
    expect(find.text('2023-2024'), findsOneWidget);
    expect(find.text('2022-2023'), findsNothing);

    await tester.drag(find.byType(Scrollable).last, const Offset(0, -160));
    await tester.pumpAndSettle();

    expect(find.text('2022-2023'), findsOneWidget);
  });
}

Widget _buildToolbar({
  required double width,
  required TextEditingController searchController,
  String sort = 'latest',
  List<String> academicYears = const ['2025-2026'],
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
            academicYears: academicYears,
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

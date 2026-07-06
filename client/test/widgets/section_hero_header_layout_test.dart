import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/water_section.dart';
import 'package:shenliyuan/screens/water_category_feed_screen.dart';
import 'package:shenliyuan/widgets/water_section/section_hero_header.dart';

void main() {
  test('默认内容板盖住今日成长卡片', () {
    final initialSize = waterSectionInitialSheetChildSize(
      screenHeight: 852,
      topInset: 44,
    );
    final sheetTop = 852 * (1 - initialSize);

    expect(sheetTop, greaterThanOrEqualTo(296));
    expect(sheetTop, lessThanOrEqualTo(308));
  });

  testWidgets('真机高状态栏下 sheet 不遮挡关注按钮', (tester) async {
    tester.view.devicePixelRatio = 3;
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.padding = const FakeViewPadding(top: 132, bottom: 102);
    addTearDown(tester.view.reset);

    const section = WaterSection(
      id: 1,
      slug: 'course_study',
      title: '课程学习',
      subtitle: '课程、考试、选课、老师、学习资料',
      iconKey: 'menu_book',
      colorHex: '#2DBE72',
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Stack(
            fit: StackFit.expand,
            children: [
              SectionHeroHeader(
                section: section,
                accentColor: Color(0xFF2DBE72),
                isFollowing: false,
                isLoggedIn: true,
                topContentInset: 112,
                onToggleFollow: _noop,
              ),
              Positioned(
                top: 360,
                left: 0,
                right: 0,
                bottom: 0,
                child: DecoratedBox(
                  key: ValueKey('water-section-sheet-test-surface'),
                  decoration: BoxDecoration(color: Colors.white),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    final followBottom = tester.getBottomLeft(find.text('+ 关注')).dy;
    final sheetTop = tester
        .getTopLeft(
          find.byKey(const ValueKey('water-section-sheet-test-surface')),
        )
        .dy;

    expect(sheetTop, greaterThanOrEqualTo(followBottom + 12));
  });
}

void _noop() {}

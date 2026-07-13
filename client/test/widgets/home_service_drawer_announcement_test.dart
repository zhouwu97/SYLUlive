import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/announcement.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/widgets/home_service_drawer.dart';

Announcement _announcement({
  required int id,
  required String title,
  String priority = 'normal',
}) {
  return Announcement(
    id: id,
    title: title,
    content: '$title 正文',
    createdBy: 1,
    createdAt: DateTime(2026, 7, 13, 12, id),
    priority: priority,
  );
}

Widget _buildDrawer({
  required List<Announcement> announcements,
  required List<Announcement> unreadAnnouncements,
}) {
  return ChangeNotifierProvider(
    create: (_) => ThemeProvider(loadOnStart: false),
    child: MaterialApp(
      home: Scaffold(
        body: HomeServiceDrawer(
          checkedIn: true,
          streakDays: 1,
          checkInLoading: false,
          showCheckInDot: false,
          announcements: announcements,
          unreadAnnouncements: unreadAnnouncements,
          onCheckIn: () {},
          onOpenToolbox: () {},
          onOpenAnnouncements: () {},
          onOpenCompetitions: () {},
          onOpenGrades: () {},
          onOpenExamSchedule: () {},
          onOpenFeedback: () {},
          onOpenWaterSectionDirectory: () {},
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('全部已读时仍展示最新公告，且不显示未读红点', (tester) async {
    final latest = _announcement(id: 2, title: '最新历史公告');

    await tester.pumpWidget(
      _buildDrawer(
        announcements: [latest],
        unreadAnnouncements: const [],
      ),
    );

    expect(find.text('公告中心'), findsOneWidget);
    expect(find.text('最新历史公告'), findsOneWidget);
    expect(find.textContaining('条未读'), findsNothing);
    expect(find.text('暂无未读公告'), findsNothing);
  });

  testWidgets('有未读时预览优先级最高的公告并显示未读数量', (tester) async {
    final normal = _announcement(id: 3, title: '普通公告');
    final urgent = _announcement(id: 1, title: '紧急公告', priority: 'urgent');

    await tester.pumpWidget(
      _buildDrawer(
        announcements: [normal, urgent],
        unreadAnnouncements: [urgent, normal],
      ),
    );

    expect(find.text('公告中心'), findsOneWidget);
    expect(find.text('紧急公告'), findsOneWidget);
    expect(find.text('2 条未读'), findsOneWidget);
  });
}

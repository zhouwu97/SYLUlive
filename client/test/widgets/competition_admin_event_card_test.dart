import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/competition.dart';
import 'package:shenliyuan/widgets/competition/competition_admin_event_card.dart';

void main() {
  testWidgets('Catalog 卡片只展示只读入口', (tester) async {
    final event = CompetitionEvent.fromJson({
      'id': 1,
      'competition_id': 'NAT-001',
      'title': '目录赛事',
      'status': 'draft',
      'management_source': 'catalog',
      'mutable': false,
      'catalog_package_id': 3,
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CompetitionAdminEventCard(
            event: event,
            onTap: () {},
            onEdit: () {},
            onPublish: () {},
            onArchive: () {},
            onDelete: () {},
          ),
        ),
      ),
    );

    expect(find.text('目录只读'), findsOneWidget);
    expect(find.text('发布'), findsNothing);
    expect(find.text('编辑'), findsNothing);
    expect(find.byTooltip('更多操作'), findsNothing);
  });
}

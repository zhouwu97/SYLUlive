import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/admin_user_summary.dart';

void main() {
  test('管理员用户摘要保留双标识和管理字段', () {
    final user = AdminUserSummary.fromJson({
      'id': 123,
      'student_id': '20260001',
      'nickname': '管理员',
      'avatar': '/uploads/avatar.png',
      'role': 'admin',
      'credit_score': 95,
      'report_count': 1,
      'edu_bound': true,
    });

    expect(user.id, 123);
    expect(user.studentId, '20260001');
    expect(user.isAdmin, isTrue);
    expect(user.isSuperAdmin, isFalse);
    expect(user.publicIdLabel, '用户 ID：123');
    expect(user.accountLabel, '学号/账号：20260001');
  });

  test('管理员用户摘要为缺失字段提供安全默认值', () {
    final user = AdminUserSummary.fromJson(const {'id': 7});

    expect(user.studentId, isEmpty);
    expect(user.creditScore, 100);
    expect(user.accountLabel, '学号/账号：未填写');
  });
}

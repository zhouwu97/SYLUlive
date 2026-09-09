import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/user.dart';

void main() {
  test('本机或旧教务连接状态不能推断学生认证', () {
    expect(User.fromJson({'id': 1, 'edu_bound': true}).studentVerified, false);
    expect(User.fromJson({'id': 1, 'student_verified': false, 'edu_bound': true}).studentVerified, false);
    expect(User.fromJson({'id': 1, 'student_verified': true, 'edu_bound': false}).studentVerified, true);
  });
}

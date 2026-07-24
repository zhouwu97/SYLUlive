import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/providers/major_provider.dart';

void main() {
  test('专业评价解析评价人头像', () {
    final rating = MajorRating.fromJson(<String, dynamic>{
      'id': 12,
      'major_id': 4,
      'user_id': 9,
      'star': 5,
      'comment': '课程设置合理',
      'user_name': '评价用户',
      'user_avatar': '/uploads/avatars/major-rating-user.png',
    });

    expect(rating.majorId, 4);
    expect(rating.userId, 9);
    expect(rating.userName, '评价用户');
    expect(
      rating.userAvatar,
      '/uploads/avatars/major-rating-user.png',
    );
  });
}

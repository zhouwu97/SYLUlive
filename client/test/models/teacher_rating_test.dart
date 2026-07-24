import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/teacher.dart';

void main() {
  test('TeacherRating parses the author profile fields', () {
    final rating = TeacherRating.fromJson(<String, dynamic>{
      'id': 12,
      'teacher_id': 4,
      'user_id': 9,
      'star': 5,
      'comment': 'Clear explanation',
      'user_name': 'Rating user',
      'user_avatar': '/uploads/avatars/rating-user.png',
    });

    expect(rating.teacherId, 4);
    expect(rating.userId, 9);
    expect(rating.userName, 'Rating user');
    expect(rating.userAvatar, '/uploads/avatars/rating-user.png');
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/post.dart';
import 'package:shenliyuan/models/water_section.dart';
import 'package:shenliyuan/models/water_team.dart';

void main() {
  group('组队模型解析', () {
    test('TeamRecruitmentMeta 解析状态、权限和方向', () {
      final meta = TeamRecruitmentMeta.fromJson({
        'recruitment_id': 12,
        'needed_count': 4,
        'accepted_count': 2,
        'remaining_count': 2,
        'roles': ['前端开发', 'UI 设计'],
        'deadline': '2026-07-20T12:00:00Z',
        'status': 'recruiting',
        'effective_status': 'recruiting',
        'application_count': 3,
        'my_application_status': 'pending',
        'is_owner': true,
        'can_apply': false,
        'can_manage': true,
      });

      expect(meta.recruitmentId, 12);
      expect(meta.roles, ['前端开发', 'UI 设计']);
      expect(meta.isRecruiting, isTrue);
      expect(meta.isPending, isTrue);
      expect(meta.isOwner, isTrue);
      expect(meta.canManage, isTrue);
      expect(meta.canApply, isFalse);
      expect(meta.toJson()['effective_status'], 'recruiting');
    });

    test('WaterTeamApplication 解析申请人和帖子摘要', () {
      final application = WaterTeamApplication.fromJson({
        'id': 7,
        'recruitment_id': 12,
        'post_id': 99,
        'applicant_id': 3,
        'owner_id': 8,
        'message': '我熟悉 Flutter 和接口联调',
        'availability': '工作日晚间',
        'status': 'pending',
        'created_at': '2026-07-10T10:00:00Z',
        'updated_at': '2026-07-10T10:00:00Z',
        'applicant': {'id': 3, 'nickname': '申请人'},
        'post': {
          'id': 99,
          'title': '创新大赛组队',
          'content': '寻找队友',
          'board_id': 1,
          'author_id': 8,
          'created_at': '2026-07-09T10:00:00Z',
        },
      });

      expect(application.id, 7);
      expect(application.status, 'pending');
      expect(application.applicant?.nickname, '申请人');
      expect(application.post?.title, '创新大赛组队');
    });

    test('Post copyWith 支持显式清空组队元数据', () {
      final post = Post.fromJson({
        'id': 1,
        'content': '正文',
        'board_id': 1,
        'author_id': 2,
        'created_at': '2026-07-10T10:00:00Z',
        'team_recruitment_meta': {
          'recruitment_id': 12,
          'effective_status': 'closed',
          'status': 'closed',
          'roles': [],
        },
      });

      expect(post.copyWith(clearTeamRecruitmentMeta: true).teamRecruitment,
          isNull);
      expect(post.copyWith(clearTeamRecruitment: true).teamRecruitment, isNull);
    });
  });

  test('WaterSectionTag 读取 content_mode，并使用 standard 作为默认值', () {
    expect(
      WaterSectionTag.fromJson({'id': 1, 'section_id': 2, 'name': '普通'})
          .contentMode,
      'standard',
    );
    expect(
      WaterSectionTag.fromJson({
        'id': 2,
        'section_id': 2,
        'name': '组队',
        'content_mode': 'team_recruitment',
      }).isTeamRecruitment,
      isTrue,
    );
  });
}

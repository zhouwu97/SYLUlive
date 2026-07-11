import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/exam_paper.dart';

void main() {
  test('试卷模型解析公开字段且不依赖私有路径', () {
    final paper = ExamPaper.fromJson({
      'id': 12,
      'status': 'published',
      'source': 'user',
      'course_name': '高等数学',
      'academic_year': '2025-2026',
      'semester': 'first',
      'exam_type': 'final',
      'title': '高等数学 · 2025-2026 · 第一学期 · 期末',
      'file_size': 2048,
      'download_count': 7,
      'reward_revocable': true,
      'published_at': '2026-07-10T10:00:00Z',
      'created_at': '2026-07-09T10:00:00Z',
      'contributor': {
        'id': 8,
        'avatar': '/uploads/avatar.png',
        'nickname': '贡献者',
        'level': 4,
      },
    });

    expect(paper.id, 12);
    expect(paper.isPublished, isTrue);
    expect(paper.semesterLabel, '第一学期');
    expect(paper.examTypeLabel, '期末');
    expect(paper.contributor.nickname, '贡献者');
    expect(paper.contributor.level, 4);
    expect(paper.fileSizeLabel, '2.0 KB');
    expect(paper.rewardRevocable, isTrue);
  });

  test('试卷模型在 reward_revocable 缺失时默认不可撤销经验', () {
    final paper = ExamPaper.fromJson(const <String, dynamic>{});

    expect(paper.rewardRevocable, isFalse);
  });

  test('直接构造试卷时默认不可撤销经验', () {
    final paper = ExamPaper(
      id: 1,
      status: 'pending',
      source: 'user',
      courseName: '高等数学',
      academicYear: '2025-2026',
      semester: 'first',
      examType: 'final',
      title: '高等数学期末试卷',
      fileSize: 1024,
      downloadCount: 0,
      approvalReason: '',
      unpublishReason: '',
      publishedAt: null,
      unpublishedAt: null,
      createdAt: DateTime(2026, 7, 11),
      contributor: const ExamPaperContributor(
        id: 1,
        avatar: '',
        nickname: '投稿人',
        level: 1,
      ),
    );

    expect(paper.rewardRevocable, isFalse);
  });

  test('分页响应解析 items/page/page_size/total', () {
    final page = ExamPaperPage.fromJson({
      'items': [
        {
          'id': 1,
          'status': 'pending',
          'source': 'user',
          'course_name': '线性代数',
          'academic_year': '2024-2025',
          'semester': 'second',
          'exam_type': 'midterm',
          'title': '线性代数 · 2024-2025 · 第二学期 · 期中',
          'file_size': 100,
          'download_count': 0,
          'created_at': '2026-07-10T10:00:00Z',
          'contributor': {'id': 2, 'avatar': '', 'nickname': '同学', 'level': 1},
        },
      ],
      'page': 2,
      'page_size': 20,
      'total': 45,
    });

    expect(page.items, hasLength(1));
    expect(page.page, 2);
    expect(page.pageSize, 20);
    expect(page.total, 45);
    expect(page.hasMore, isTrue);
  });

  test('学年选项以九月为界并生成服务端同款标题预览', () {
    expect(
      ExamPaperMetadata.academicYears(DateTime(2026, 8, 31)).first,
      '2025-2026',
    );
    expect(
      ExamPaperMetadata.academicYears(DateTime(2026, 9, 1)).first,
      '2026-2027',
    );
    expect(
      ExamPaperMetadata.buildTitle(
        courseName: '  大学物理 ',
        academicYear: '2025-2026',
        semester: 'other',
        examType: 'retake',
      ),
      '大学物理 · 2025-2026 · 其他 · 重修',
    );
  });
}

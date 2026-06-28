import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/campus_article.dart';

void main() {
  group('CampusArticleSummary.fromJson', () {
    test('列表 JSON 不含正文和附件', () {
      final json = {
        'id': 2,
        'source': 'jwc',
        'category': '教务通知',
        'category_slug': 'jwtz',
        'title': '2025-2026-2经济管理学院期末考试安排 17周',
        'publish_date': '2026-06-23',
        'author_department': '教务管理科',
        'source_url': 'https://jwc.sylu.edu.cn/jwtz/123.htm',
        'has_attachment': true,
      };
      final s = CampusArticleSummary.fromJson(json);
      expect(s.id, 2);
      expect(s.source, 'jwc');
      expect(s.category, '教务通知');
      expect(s.categorySlug, 'jwtz');
      expect(s.title, '2025-2026-2经济管理学院期末考试安排 17周');
      expect(s.publishDate, '2026-06-23');
      expect(s.authorDepartment, '教务管理科');
      expect(s.hasAttachment, true);
    });

    test('字段为 null 时不崩溃', () {
      final json = <String, dynamic>{
        'id': null,
        'title': null,
        'category': null,
        'category_slug': null,
        'publish_date': null,
        'author_department': null,
        'source_url': null,
        'has_attachment': null,
      };
      final s = CampusArticleSummary.fromJson(json);
      expect(s.id, 0);
      expect(s.title, '');
      expect(s.category, '');
      expect(s.hasAttachment, false);
    });

    test('id 为字符串时也能解析', () {
      final json = {'id': '42', 'title': 'Test'};
      final s = CampusArticleSummary.fromJson(json);
      expect(s.id, 42);
    });

    test('shortDate 从 publish_date 提取 MM-DD', () {
      final s = CampusArticleSummary(
        id: 1,
        publishDate: '2026-06-23',
      );
      expect(s.shortDate, '06-23');
    });

    test('shortDate 在 publish_date 不完整时返回原值', () {
      final s = CampusArticleSummary(
        id: 1,
        publishDate: '2026',
      );
      expect(s.shortDate, '2026');
    });
  });

  group('CampusArticleDetail.fromJson', () {
    test('详情 JSON 含一个附件', () {
      final json = {
        'id': 3,
        'title': '关于期末考试的通知',
        'category': '教务通知',
        'category_slug': 'jwtz',
        'publish_date': '2026-06-20',
        'author_department': '教务管理科',
        'source_url': 'https://jwc.sylu.edu.cn/jwtz/3.htm',
        'has_attachment': true,
        'content_text': '请各位同学注意考试时间安排。',
        'content_html': '<p>请各位同学注意考试时间安排。</p>',
        'attachments': [
          {
            'name': '考试安排表.xls',
            'url': 'https://jwc.sylu.edu.cn/files/exam.xls',
            'extension': 'xls',
          }
        ],
      };
      final d = CampusArticleDetail.fromJson(json);
      expect(d.id, 3);
      expect(d.title, '关于期末考试的通知');
      expect(d.contentText, '请各位同学注意考试时间安排。');
      expect(d.attachments.length, 1);
      expect(d.attachments.first.name, '考试安排表.xls');
      expect(d.attachments.first.url, 'https://jwc.sylu.edu.cn/files/exam.xls');
      expect(d.attachments.first.extension, 'xls');
    });

    test('attachments 为空数组', () {
      final json = {
        'id': 5,
        'title': '无附件通知',
        'attachments': [],
        'has_attachment': false,
      };
      final d = CampusArticleDetail.fromJson(json);
      expect(d.attachments, isEmpty);
      expect(d.hasAttachment, false);
    });

    test('attachments 字段缺失', () {
      final json = <String, dynamic>{
        'id': 5,
        'title': '无附件字段的通知',
      };
      final d = CampusArticleDetail.fromJson(json);
      expect(d.attachments, isEmpty);
    });

    test('content_text 为"详见附件："时识别为弱正文', () {
      final d = CampusArticleDetail(
        id: 1,
        contentText: '详见附件：',
        attachments: [
          CampusAttachment(
              name: 'file.doc',
              url: 'https://jwc.sylu.edu.cn/f.doc',
              extension: 'doc'),
        ],
      );
      expect(d.isWeakContent, true);
    });

    test('content_text 为"详见附件"时识别为弱正文', () {
      final d = CampusArticleDetail(
        id: 1,
        contentText: '详见附件',
        attachments: [],
      );
      expect(d.isWeakContent, true);
    });

    test('content_text 为"见附件"时识别为弱正文', () {
      final d = CampusArticleDetail(
        id: 1,
        contentText: '见附件',
      );
      expect(d.isWeakContent, true);
    });

    test('content_text 为空字符串时识别为弱正文', () {
      final d = CampusArticleDetail(
        id: 1,
        contentText: '',
      );
      expect(d.isWeakContent, true);
    });

    test('content_text 有实际内容时不识别为弱正文', () {
      final d = CampusArticleDetail(
        id: 1,
        contentText: '请各位同学注意考试时间安排。详见附件中的具体时间表。',
      );
      expect(d.isWeakContent, false);
    });

    test('hasComplexHtml 检测表格', () {
      final d = CampusArticleDetail(
        id: 1,
        contentHtml: '<table><tr><td>数据</td></tr></table>',
      );
      expect(d.hasComplexHtml, true);
    });

    test('hasComplexHtml 检测图片', () {
      final d = CampusArticleDetail(
        id: 1,
        contentHtml: '<img src="photo.jpg" />',
      );
      expect(d.hasComplexHtml, true);
    });

    test('hasComplexHtml 纯文本时返回 false', () {
      final d = CampusArticleDetail(
        id: 1,
        contentHtml: '<p>这是纯文本段落。</p>',
      );
      expect(d.hasComplexHtml, false);
    });

    test('fromSummary 保留摘要字段', () {
      final s = CampusArticleSummary(
        id: 10,
        title: '测试标题',
        category: '教务公告',
        categorySlug: 'jwgg',
        publishDate: '2026-06-25',
        authorDepartment: '教务处',
        sourceUrl: 'https://jwc.sylu.edu.cn/jwgg/10.htm',
        hasAttachment: true,
      );
      final d = CampusArticleDetail.fromSummary(s);
      expect(d.id, 10);
      expect(d.title, '测试标题');
      expect(d.category, '教务公告');
      expect(d.contentText, '');
      expect(d.attachments, isEmpty);
    });
  });

  group('CampusAttachment', () {
    test('未知扩展名使用通用图标', () {
      final a = CampusAttachment(
        name: 'file.unknown',
        url: 'https://jwc.sylu.edu.cn/f.unknown',
        extension: 'unknown',
      );
      // 只验证不崩溃，IconData 具体值不做断言
      expect(a.extensionLabel, 'UNKNOWN');
    });

    test('isUrlSafe 仅允许 jwc.sylu.edu.cn 的 HTTPS', () {
      expect(
        CampusAttachment(
          name: 'f.xls',
          url: 'https://jwc.sylu.edu.cn/f.xls',
          extension: 'xls',
        ).isUrlSafe,
        true,
      );
      expect(
        CampusAttachment(
          name: 'f.xls',
          url: 'http://jwc.sylu.edu.cn/f.xls',
          extension: 'xls',
        ).isUrlSafe,
        false,
      );
      expect(
        CampusAttachment(
          name: 'f.xls',
          url: 'https://evil.com/f.xls',
          extension: 'xls',
        ).isUrlSafe,
        false,
      );
    });

    test('extensionLabel 空扩展名显示"附件"', () {
      const a = CampusAttachment(
          name: 'file', url: 'https://jwc.sylu.edu.cn/f', extension: '');
      expect(a.extensionLabel, '附件');
    });
  });

  group('CampusArticlePage.fromJson', () {
    test('正常分页响应', () {
      final json = {
        'items': [
          {'id': 1, 'title': '第一篇'},
          {'id': 2, 'title': '第二篇'},
        ],
        'page': 1,
        'page_size': 20,
        'has_more': true,
        'last_sync_at': '2026-06-23T10:00:00+08:00',
      };
      final p = CampusArticlePage.fromJson(json);
      expect(p.items.length, 2);
      expect(p.page, 1);
      expect(p.pageSize, 20);
      expect(p.hasMore, true);
      expect(p.lastSyncAt, isNotNull);
    });

    test('last_sync_at 为 null', () {
      final json = {
        'items': [],
        'page': 1,
        'page_size': 20,
        'has_more': false,
      };
      final p = CampusArticlePage.fromJson(json);
      expect(p.items, isEmpty);
      expect(p.hasMore, false);
      expect(p.lastSyncAt, isNull);
    });

    test('items 为 null 不崩溃', () {
      final json = <String, dynamic>{
        'items': null,
        'page': 1,
        'page_size': 20,
        'has_more': false,
      };
      final p = CampusArticlePage.fromJson(json);
      expect(p.items, isEmpty);
    });
  });
}

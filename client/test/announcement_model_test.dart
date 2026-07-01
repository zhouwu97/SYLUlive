import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/announcement.dart';

void main() {
  group('Announcement.fromJson backward compatibility', () {
    test('parses created_by field (new format)', () {
      final json = {
        'id': 1,
        'title': 'Test',
        'content': 'Content',
        'created_by': 42,
        'created_at': '2026-06-24T12:00:00Z',
      };
      final a = Announcement.fromJson(json);
      expect(a.createdBy, 42);
    });

    test('parses author_id field (old format fallback)', () {
      final json = {
        'id': 1,
        'title': 'Test',
        'content': 'Content',
        'author_id': 99,
        'created_at': '2026-06-24T12:00:00Z',
      };
      final a = Announcement.fromJson(json);
      expect(a.createdBy, 99);
    });

    test('created_by takes precedence over author_id', () {
      final json = {
        'id': 1,
        'title': 'Test',
        'content': 'Content',
        'created_by': 42,
        'author_id': 99,
        'created_at': '2026-06-24T12:00:00Z',
      };
      final a = Announcement.fromJson(json);
      expect(a.createdBy, 42);
    });

    test('parses priority as String (new format)', () {
      final json = {
        'id': 1,
        'title': 'Test',
        'content': 'Content',
        'created_at': '2026-06-24T12:00:00Z',
        'priority': 'urgent',
      };
      final a = Announcement.fromJson(json);
      expect(a.priority, 'urgent');
    });

    test('parses priority as int (old format): 2 → urgent', () {
      final json = {
        'id': 1,
        'title': 'Test',
        'content': 'Content',
        'created_at': '2026-06-24T12:00:00Z',
        'priority': 2,
      };
      final a = Announcement.fromJson(json);
      expect(a.priority, 'urgent');
    });

    test('parses priority as int (old format): 1 → important', () {
      final json = {
        'id': 1,
        'title': 'Test',
        'content': 'Content',
        'created_at': '2026-06-24T12:00:00Z',
        'priority': 1,
      };
      final a = Announcement.fromJson(json);
      expect(a.priority, 'important');
    });

    test('parses priority as int (old format): 0 → normal', () {
      final json = {
        'id': 1,
        'title': 'Test',
        'content': 'Content',
        'created_at': '2026-06-24T12:00:00Z',
        'priority': 0,
      };
      final a = Announcement.fromJson(json);
      expect(a.priority, 'normal');
    });

    test('missing priority defaults to normal', () {
      final json = {
        'id': 1,
        'title': 'Test',
        'content': 'Content',
        'created_at': '2026-06-24T12:00:00Z',
      };
      final a = Announcement.fromJson(json);
      expect(a.priority, 'normal');
    });

    test('parses all new fields', () {
      final json = {
        'id': 1,
        'title': 'Test',
        'content': 'Content',
        'created_by': 42,
        'creator': {'id': 42, 'nickname': 'Admin'},
        'created_at': '2026-06-24T12:00:00Z',
        'updated_at': '2026-06-24T13:00:00Z',
        'is_pinned': true,
        'status': 'published',
        'display_mode': 'modal',
        'priority': 'urgent',
        'publish_at': '2026-06-25T00:00:00Z',
        'expires_at': '2026-07-01T00:00:00Z',
        'include_new_users': true,
      };
      final a = Announcement.fromJson(json);
      expect(a.id, 1);
      expect(a.title, 'Test');
      expect(a.content, 'Content');
      expect(a.createdBy, 42);
      expect(a.creator, isNotNull);
      expect(a.creator!['nickname'], 'Admin');
      expect(a.isPinned, true);
      expect(a.status, 'published');
      expect(a.displayMode, 'modal');
      expect(a.priority, 'urgent');
      expect(a.publishAt, isNotNull);
      expect(a.expiresAt, isNotNull);
      expect(a.includeNewUsers, true);
    });

    test('isModalUrgent returns true for urgent + modal', () {
      final a = Announcement(
        id: 1,
        title: 'Test',
        content: 'Content',
        createdBy: 1,
        createdAt: DateTime.now(),
        priority: 'urgent',
        displayMode: 'modal',
      );
      expect(a.isModalUrgent, true);
    });

    test('isModalUrgent returns true for important + modal', () {
      final a = Announcement(
        id: 1,
        title: 'Test',
        content: 'Content',
        createdBy: 1,
        createdAt: DateTime.now(),
        priority: 'important',
        displayMode: 'modal',
      );
      expect(a.isModalUrgent, true);
    });

    test('isModalUrgent returns false for urgent + center', () {
      final a = Announcement(
        id: 1,
        title: 'Test',
        content: 'Content',
        createdBy: 1,
        createdAt: DateTime.now(),
        priority: 'urgent',
        displayMode: 'center',
      );
      expect(a.isModalUrgent, false);
    });

    test('isModalUrgent returns false for normal + modal', () {
      final a = Announcement(
        id: 1,
        title: 'Test',
        content: 'Content',
        createdBy: 1,
        createdAt: DateTime.now(),
        priority: 'normal',
        displayMode: 'modal',
      );
      expect(a.isModalUrgent, false);
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/canteen_dish.dart';
import 'package:shenliyuan/models/canteen_home.dart';

void main() {
  group('CanteenDish.hasDisplayImage', () {
    test('有封面地址时判定为有图', () {
      const dish = CanteenDish(
        id: 1,
        name: '锅包肉',
        coverImage: '/uploads/a.jpg',
        photoCount: 1,
        lastPhotoAt: '2026-08-13',
      );
      expect(dish.hasDisplayImage, isTrue);
    });

    test('空地址与纯空白地址判定为无图', () {
      const empty = CanteenDish(
        id: 1,
        name: '锅包肉',
        coverImage: '',
        photoCount: 0,
        lastPhotoAt: '',
      );
      const blank = CanteenDish(
        id: 2,
        name: '凉菜',
        coverImage: '   ',
        photoCount: 0,
        lastPhotoAt: '',
      );
      expect(empty.hasDisplayImage, isFalse);
      expect(blank.hasDisplayImage, isFalse);
    });

    test('fromJson 缺少 cover_image 字段时判定为无图', () {
      final dish = CanteenDish.fromJson({
        'id': 3,
        'name': '火锅牛肉米线',
        'photo_count': 1,
      });
      expect(dish.coverImage, isEmpty);
      expect(dish.hasDisplayImage, isFalse);
    });
  });

  group('CanteenHotDish.hasDisplayImage', () {
    test('有封面地址时判定为有图', () {
      const dish = CanteenHotDish(
        id: 11,
        name: '麻辣拌',
        canteenId: 1,
        canteenName: '一食堂二楼',
        coverImage: '/uploads/a.jpg',
      );
      expect(dish.hasDisplayImage, isTrue);
    });

    test('空地址判定为无图，热门菜品不应生成占位卡', () {
      const dish = CanteenHotDish(
        id: 12,
        name: '杂粮煎饼',
        canteenId: 2,
        canteenName: '二食堂',
      );
      expect(dish.hasDisplayImage, isFalse);
    });
  });
}

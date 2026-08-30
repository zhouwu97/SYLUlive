import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/screens/image_viewer_screen.dart';
import 'package:shenliyuan/utils/canteen_pending_image_cache.dart';
import 'package:shenliyuan/widgets/app_cached_image.dart';
import 'package:shenliyuan/widgets/canteen/canteen_pending_card.dart';
import 'package:shenliyuan/widgets/canteen/canteen_pending_review_image.dart';

Widget _buildTestApp(Widget child, {AuthProvider? authProvider}) {
  return MultiProvider(
    providers: [
      if (authProvider != null)
        ChangeNotifierProvider<AuthProvider>.value(value: authProvider)
      else
        Provider<AuthProvider?>.value(value: null),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: child,
          ),
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CanteenPendingCard 待审核食堂卡片重构测试', () {
    testWidgets('长店名完整展示（最多2行）且移除「新食堂：」前缀', (tester) async {
      const longName = '南区教工第一餐厅·朱海龙潮汕鲜牛肉火锅及老砂锅煲仔饭专门店';
      final canteen = {
        'id': 101,
        'name': longName,
        'creator_name': '张三同学',
        'created_at': '2026-08-28T09:30:00Z',
        'image': '',
      };

      await tester.pumpWidget(
        _buildTestApp(
          CanteenPendingCard(
            canteen: canteen,
            isDark: false,
          ),
        ),
      );
      await tester.pump();

      // 验证未包含「新食堂：」前缀
      expect(find.textContaining('新食堂：'), findsNothing);

      // 验证长店名完整找到
      final titleFinder = find.text(longName);
      expect(titleFinder, findsOneWidget);

      final textWidget = tester.widget<Text>(titleFinder);
      expect(textWidget.maxLines, equals(2));
      expect(textWidget.overflow, equals(TextOverflow.ellipsis));

      // 验证提交人与提交时间
      expect(find.textContaining('张三同学'), findsOneWidget);
      expect(find.textContaining('提交时间：'), findsOneWidget);

      // 验证无图状态
      expect(find.text('未上传门面图'), findsOneWidget);
    });

    testWidgets('有门面图时使用 AppCachedImage.private 加载并透传 Authorization 头与内存解码限制',
        (tester) async {
      const token = 'admin_jwt_secret_token_123';
      final canteen = {
        'id': 202,
        'name': '清真风味餐厅',
        'creator_name': '李四',
        'created_at': '2026-08-28T10:00:00Z',
        'image': '/uploads/canteen/halal_front.jpg',
      };

      await tester.pumpWidget(
        _buildTestApp(
          CanteenPendingCard(
            canteen: canteen,
            isDark: false,
            token: token,
            accountId: 999,
          ),
        ),
      );
      await tester.pump();

      // 检查待审核专用图片组件
      final reviewImageFinder = find.byType(CanteenPendingReviewImage);
      expect(reviewImageFinder, findsOneWidget);

      // 检查底层 AppCachedImage
      final cachedImageFinder = find.byType(AppCachedImage);
      expect(cachedImageFinder, findsOneWidget);

      final cachedImage = tester.widget<AppCachedImage>(cachedImageFinder);
      expect(cachedImage.httpHeaders?['Authorization'], equals('Bearer $token'));
      expect(cachedImage.cacheManager, equals(CanteenPendingImageCache.instance.manager));
      expect(cachedImage.cacheKey, startsWith('canteen_pending:999:'));
      expect(cachedImage.memCacheWidth, equals(720));
      expect(cachedImage.memCacheHeight, equals(405));
    });

    testWidgets('点击图片打开全屏 ImageViewerScreen 并继承相同的 Authorization 与私有 CacheManager',
        (tester) async {
      const token = 'test_token_admin_xyz';
      final canteen = {
        'id': 303,
        'name': '快乐炸鸡汉堡',
        'creator_name': '王五',
        'created_at': '2026-08-28T10:15:00Z',
        'image': 'canteen/chicken.png',
      };

      await tester.pumpWidget(
        _buildTestApp(
          CanteenPendingCard(
            canteen: canteen,
            isDark: false,
            token: token,
            accountId: 888,
          ),
        ),
      );
      await tester.pump();

      // 点击门面图区域
      await tester.tap(find.byType(CanteenPendingReviewImage));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // 验证打开了 ImageViewerScreen
      final viewerFinder = find.byType(ImageViewerScreen);
      expect(viewerFinder, findsOneWidget);

      final viewer = tester.widget<ImageViewerScreen>(viewerFinder);
      expect(viewer.httpHeaders['Authorization'], equals('Bearer $token'));
      expect(viewer.cacheManager, equals(CanteenPendingImageCache.instance.manager));
      expect(
        viewer.cacheKeyBuilder?.call('http://example.com/test.jpg'),
        equals('canteen_pending:888:http://example.com/test.jpg'),
      );
    });

    testWidgets('底部独立操作按钮（驳回 / 审核通过）点击回调正常且触控热区高度 >= 44px',
        (tester) async {
      var approved = false;
      var rejected = false;

      final canteen = {
        'id': 404,
        'name': '特色麻辣烫',
        'creator_name': '小赵',
        'image': '',
      };

      await tester.pumpWidget(
        _buildTestApp(
          CanteenPendingCard(
            canteen: canteen,
            isDark: false,
            onApprove: () async => approved = true,
            onReject: () async => rejected = true,
          ),
        ),
      );
      await tester.pump();

      final rejectBtnFinder = find.widgetWithText(OutlinedButton, '驳回');
      final approveBtnFinder = find.widgetWithText(FilledButton, '审核通过');

      expect(rejectBtnFinder, findsOneWidget);
      expect(approveBtnFinder, findsOneWidget);

      // 验证按钮触控热区高度 >= 44px
      final rejectSize = tester.getSize(rejectBtnFinder);
      final approveSize = tester.getSize(approveBtnFinder);
      expect(rejectSize.height, greaterThanOrEqualTo(44.0));
      expect(approveSize.height, greaterThanOrEqualTo(44.0));

      // 点击驳回
      await tester.tap(rejectBtnFinder);
      expect(rejected, isTrue);

      // 点击通过
      await tester.tap(approveBtnFinder);
      expect(approved, isTrue);
    });

    testWidgets('深色模式正常渲染', (tester) async {
      final canteen = {
        'id': 505,
        'name': '风味小炒',
        'creator_name': '测试员',
        'image': '',
      };

      await tester.pumpWidget(
        _buildTestApp(
          CanteenPendingCard(
            canteen: canteen,
            isDark: true,
          ),
        ),
      );
      await tester.pump();

      expect(find.text('风味小炒'), findsOneWidget);
      expect(find.text('未上传门面图'), findsOneWidget);
    });
  });
}

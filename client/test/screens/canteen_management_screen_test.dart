import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/canteen.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/canteen_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/screens/admin_canteen_editor_screen.dart';
import 'package:shenliyuan/screens/admin_canteen_operations_screen.dart';
import 'package:shenliyuan/screens/canteen_submit_screen.dart';
import 'package:shenliyuan/widgets/image_upload_widget.dart';

import '../helpers/golden_test_app.dart';
import '../helpers/load_test_fonts.dart';
import '../helpers/mock_public_image_http.dart';

class _Auth extends ChangeNotifier implements AuthProvider {
  _Auth(this.client, {this.role = 'admin'});
  final Dio client;
  String role;
  int epoch = 1;
  @override
  User get user => User(
      id: 7,
      studentId: 'fixture',
      nickname: '测试管理员',
      role: role,
      createdAt: DateTime(2026));
  @override
  bool get isLoggedIn => true;
  @override
  int get accountSessionEpoch => epoch;
  @override
  int get sessionGeneration => epoch;
  @override
  Dio get dio => client;
  void relogin() {
    epoch++;
    notifyListeners();
  }

  void revoke() {
    role = 'user';
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Picker extends ImagePickerPlatform {
  XFile? file;
  Completer<XFile?>? pending;
  bool denied = false;
  @override
  Future<XFile?> getImageFromSource(
      {required ImageSource source,
      ImagePickerOptions options = const ImagePickerOptions()}) async {
    if (denied) throw PlatformException(code: 'photo_access_denied');
    if (pending != null) return pending!.future;
    return file;
  }
}

const _meta = {
  'supports_unified_management': true,
  'location_areas': ['一食堂', '二食堂', '其他'],
  'location_floors': ['一楼', '二楼'],
};
const _shop = {
  'id': 34,
  'name': '川渝椒香',
  'verified': true,
  'image': '',
  'rating_count': 18,
  'average_star': 4.6,
  'dish_count': 8,
  'location_area': '一食堂',
  'location_floor': '二楼',
};
const _other = {
  'id': 35,
  'name': '校外小馆',
  'location_area': '其他',
  'image': '',
  'verified': true
};
const _archive = {
  'id': 36,
  'name': '旧时面馆',
  'location_area': '二食堂',
  'operating_status': 'offline',
  'offline_reason': '档口转让',
  'image': '',
  'verified': true
};
const _tags = {
  'location_area': '一食堂',
  'location_floor': '二楼',
  'tags': null,
  'automatic_tags': [
    {'key': 'taste_good', 'name': '味道不错', 'count': 8},
    {'key': 'portion_enough', 'name': '分量足', 'count': 5},
    {'key': 'good_value', 'name': '性价比高', 'count': 4},
  ],
};

Dio _dio(FutureOr<Response<dynamic>?> Function(RequestOptions) respond) {
  final dio = Dio(BaseOptions(baseUrl: 'https://fixture.invalid/api'));
  dio.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) async {
    final response = await respond(request);
    if (response == null) {
      handler.resolve(Response(
          requestOptions: request,
          statusCode: 200,
          data: request.path == '/canteens/meta' ? _meta : _tags));
    } else if ((response.statusCode ?? 200) >= 400) {
      handler.reject(DioException(
          requestOptions: request,
          response: response,
          type: DioExceptionType.badResponse));
    } else {
      handler.resolve(response);
    }
  }));
  return dio;
}

Response<dynamic> _reply(RequestOptions request, dynamic data,
        [int status = 200]) =>
    Response(requestOptions: request, statusCode: status, data: data);

Future<void> _pump(
  WidgetTester tester,
  Dio dio,
  Widget page, {
  _Auth? auth,
  ThemeMode theme = ThemeMode.light,
  double scale = 1,
  Size size = const Size(390, 844),
  GlobalKey? capture,
  bool route = false,
  bool settle = true,
  ThemeProvider? appearance,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final wrapped = RepaintBoundary(key: capture, child: page);
  await tester.pumpWidget(MultiProvider(
      providers: [
        if (appearance != null) ChangeNotifierProvider.value(value: appearance),
        ChangeNotifierProvider(create: (_) => CanteenProvider(dio)),
        ChangeNotifierProvider<AuthProvider>.value(value: auth ?? _Auth(dio)),
      ],
      child: GoldenTestApp(
        themeMode: theme,
        textScaler: TextScaler.linear(scale),
        disableAnimations: true,
        home: route
            ? Scaffold(
                body: Builder(
                    builder: (context) => TextButton(
                          onPressed: () => Navigator.push<Object?>(context,
                              MaterialPageRoute(builder: (_) => wrapped)),
                          child: const Text('打开'),
                        )))
            : wrapped,
      )));
  if (route) {
    await tester.tap(find.text('打开'));
  }
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

Future<void> _show(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

Future<void> _chooseArea(WidgetTester tester, String area) async {
  final option = find.descendant(
      of: find.byKey(const ValueKey('merchant-area')),
      matching: find.widgetWithText(ChoiceChip, area));
  await _show(tester, option);
  await tester.tap(option);
  await tester.pumpAndSettle();
}

Future<void> _toggleTagMode(WidgetTester tester) async {
  final mode = tester
      .widget<Semantics>(find.byKey(const ValueKey('merchant-tag-mode-true')))
      .properties
      .selected!;
  await tester.tap(find.text(mode ? '手动选择' : '自动汇总'));
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  await tester.pumpAndSettle();
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/canteen-management-components-qa/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(data!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

void main() {
  setUpAll(() async {
    await loadTestFonts();
    await (FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
        .load();
  });

  testWidgets('管理 → 唯一编辑入口 → 名称位置标签一次保存 → 列表刷新', (tester) async {
    var stored = Map<String, dynamic>.of(_shop);
    Map<String, dynamic>? sent;
    var writes = 0;
    final dio = _dio((r) {
      if (r.path == '/canteens/admin-list') {
        return _reply(r, {
          'items': [stored, _other]
        });
      }
      if (r.method == 'PATCH') {
        writes++;
        expect(r.path, '/canteens/34');
        expect(r.extra['expectedAuthUserId'], 7);
        expect(r.extra['expectedAuthSessionEpoch'], 1);
        sent = Map<String, dynamic>.from(r.data as Map);
        stored = {...stored, ...sent!};
        return _reply(r, {});
      }
      expect(r.method, 'GET', reason: '统一表单不应调用旧 PUT 标签接口');
      return null;
    });
    await _pump(tester, dio, const AdminCanteenOperationsScreen());
    expect(find.text('食堂管理'), findsOneWidget);
    await tester.tap(find.byTooltip('管理「川渝椒香」'));
    await tester.pumpAndSettle();
    expect(find.text('编辑商家'), findsOneWidget);
    expect(find.text('修改名称和位置'), findsNothing);
    expect(find.text('修改店铺标签'), findsNothing);
    await tester.tap(find.text('编辑商家'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '川渝新店');
    await _chooseArea(tester, '其他');
    expect(find.text('所在楼层'), findsNothing);
    await _show(tester, find.byKey(const ValueKey('merchant-tag-mode')));
    await _toggleTagMode(tester);
    await tester.pumpAndSettle();
    await _show(tester, find.widgetWithText(FilterChip, '卫生干净'));
    await tester.tap(find.widgetWithText(FilterChip, '卫生干净'));
    await tester.tap(find.text('保存修改'));
    await tester.pumpAndSettle();
    expect(writes, 1);
    expect(sent, {
      'name': '川渝新店',
      'location_area': '其他',
      'location_floor': '',
      'tags': ['clean']
    });
    expect(find.text('川渝新店'), findsOneWidget);
    expect(find.textContaining('18 人评价'), findsOneWidget);
    expect(find.byType(AdminCanteenEditorScreen), findsNothing);
  });

  testWidgets('区域与状态筛选计数一致，无结果可清除筛选，刷新失败保留数据', (tester) async {
    var fail = false;
    final dio = _dio((r) => r.path == '/canteens/admin-list'
        ? fail
            ? _reply(r, {'error': '网络不可用'}, 503)
            : _reply(r, {
                'items': [_shop, _other, _archive]
              })
        : null);
    await _pump(tester, dio, const AdminCanteenOperationsScreen());
    await tester.tap(find.byTooltip('区域筛选'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(CheckedPopupMenuItem<String>, '其他'));
    await tester.pumpAndSettle();
    expect(find.text('全部 1'), findsOneWidget);
    expect(find.text('校外小馆'), findsOneWidget);
    expect(find.text('川渝椒香'), findsNothing);
    await tester.enterText(find.byType(TextField), '不存在');
    await tester.pumpAndSettle();
    expect(find.text('没有符合条件的商家'), findsOneWidget);
    await tester.tap(find.text('清除筛选'));
    await tester.pumpAndSettle();
    expect(find.text('全部 3'), findsOneWidget);
    fail = true;
    await tester.tap(find.byTooltip('刷新商家列表'));
    await tester.pumpAndSettle();
    expect(find.textContaining('刷新失败，保留上次列表'), findsOneWidget);
    expect(find.text('川渝椒香'), findsOneWidget);
    fail = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.textContaining('刷新失败'), findsNothing);
  });

  testWidgets('管理加载失败可重试到空态，普通用户不发管理请求', (tester) async {
    var calls = 0;
    final dio = _dio((r) {
      if (r.path != '/canteens/admin-list') return null;
      calls++;
      return calls == 1 ? _reply(r, {}, 500) : _reply(r, {'items': []});
    });
    await _pump(tester, dio, const AdminCanteenOperationsScreen());
    expect(find.text('加载失败'), findsOneWidget);
    await tester.tap(find.text('重新加载'));
    await tester.pumpAndSettle();
    expect(find.text('暂无已收录商家'), findsOneWidget);
    final auth = _Auth(dio, role: 'user');
    await tester.pumpWidget(const SizedBox());
    await _pump(tester, dio, const AdminCanteenOperationsScreen(), auth: auth);
    expect(find.text('需要管理员权限'), findsOneWidget);
    expect(calls, 2);
  });

  testWidgets('同账号重新登录后，旧列表响应不回填，旧页面不可继续管理', (tester) async {
    final pending = Completer<Response<dynamic>>();
    RequestOptions? request;
    final dio = _dio((r) {
      if (r.path == '/canteens/admin-list') {
        request = r;
        return pending.future;
      }
      return null;
    });
    final auth = _Auth(dio);
    // 首次请求保持 pending，不能 pumpAndSettle 等待无限进度动画。
    await _pump(tester, dio, const AdminCanteenOperationsScreen(),
        auth: auth, settle: false);
    await tester.pump(const Duration(milliseconds: 100));
    auth.relogin();
    pending.complete(_reply(request!, {
      'items': [_shop]
    }));
    await tester.pumpAndSettle();
    expect(find.text('需要管理员权限'), findsOneWidget);
    expect(find.text('川渝椒香'), findsNothing);
  });

  testWidgets('编辑加载失败重试，手动最多三标签，失败保留输入并拦截重复保存', (tester) async {
    var loads = 0, writes = 0;
    final pending = Completer<Response<dynamic>>();
    RequestOptions? write;
    final dio = _dio((r) {
      if (r.path.endsWith('/display-tags')) {
        loads++;
        return loads == 1
            ? _reply(r, {}, 500)
            : _reply(r, {
                ..._tags,
                'tags': ['clean', 'good_value', 'taste_good']
              });
      }
      if (r.method == 'PATCH') {
        writes++;
        write = r;
        if (writes == 1) return _reply(r, {'error': '保存失败'}, 500);
        return pending.future;
      }
      return null;
    });
    await _pump(
        tester, dio, AdminCanteenEditorScreen(canteen: Canteen.fromJson(_shop)),
        route: true);
    expect(find.text('加载商家设置失败，请重试'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '更新店名');
    await _show(tester, find.widgetWithText(FilterChip, '分量足'));
    expect(
        tester
            .widget<FilterChip>(find.widgetWithText(FilterChip, '分量足'))
            .onSelected,
        isNull);
    await tester.tap(find.text('保存修改'));
    await tester.pumpAndSettle();
    expect(find.byType(AdminCanteenEditorScreen), findsOneWidget);
    expect(
        tester
            .widget<TextFormField>(find.byType(TextFormField))
            .controller!
            .text,
        '更新店名');
    await tester.tap(find.text('保存修改'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('保存中…'));
    await Navigator.of(tester.element(find.byType(AdminCanteenEditorScreen)))
        .maybePop();
    await tester.pump();
    expect(writes, 2);
    expect(find.byType(AdminCanteenEditorScreen), findsOneWidget);
    expect(
        tester
            .widgetList<ChoiceChip>(find.byType(ChoiceChip))
            .every((option) => option.onSelected == null),
        isTrue);
    expect(
        tester
            .widget<IconButton>(
                find.byKey(const ValueKey('merchant-name-clear')))
            .onPressed,
        isNull);
    pending.complete(_reply(write!, {}));
    await tester.pumpAndSettle();
    expect(find.byType(AdminCanteenEditorScreen), findsNothing);
  });

  testWidgets('编辑页展示真实资料，名称位置与手动标签预览随草稿更新', (tester) async {
    final dio = _dio((_) => null);
    await _pump(tester, dio,
        AdminCanteenEditorScreen(canteen: Canteen.fromJson(_shop)));
    expect(find.byTooltip('暂无封面'), findsOneWidget);
    expect(find.text('4.6'), findsOneWidget);
    expect(find.text('18 人评价'), findsOneWidget);
    expect(find.text('8 道菜 · 0 张实拍'), findsOneWidget);
    expect(find.byTooltip('8 次提及'), findsOneWidget);
    List<String?> previewTags() => tester
        .widgetList<Text>(find.descendant(
            of: find.byKey(const ValueKey('merchant-tag-preview')),
            matching: find.byWidgetPredicate((widget) =>
                widget is Text &&
                widget.key is ValueKey<String> &&
                (widget.key! as ValueKey<String>)
                    .value
                    .startsWith('preview-tag-'))))
        .map((text) => text.data)
        .toList();
    expect(previewTags(), ['味道不错', '分量足', '性价比高']);
    await tester.enterText(find.byType(TextFormField), '川渝新店');
    await tester.tap(find.byTooltip('清空商家名称'));
    await tester.pumpAndSettle();
    expect(find.text('商家名称需为 2–100 个字符'), findsOneWidget);
    expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('merchant-preview-name')))
            .data,
        '商家名称');
    await tester.enterText(find.byType(TextFormField), '川渝新店');
    await _show(tester, find.byKey(const ValueKey('merchant-area')));
    await _chooseArea(tester, '其他');
    expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('merchant-preview-name')))
            .data,
        '川渝新店');
    expect(
        tester
            .widget<Semantics>(
                find.byKey(const ValueKey('merchant-preview-location')))
            .properties
            .label,
        '营业中 · 其他');
    await _chooseArea(tester, '其他');
    expect(find.byKey(const ValueKey('merchant-floor')), findsOneWidget);
    expect(
        tester
            .widgetList<ChoiceChip>(find.descendant(
                of: find.byKey(const ValueKey('merchant-floor')),
                matching: find.byType(ChoiceChip)))
            .every((option) => !option.selected),
        isTrue,
        reason: '离开其他区域后不能恢复此前清空的楼层');
    expect(
        tester
            .widget<Semantics>(
                find.byKey(const ValueKey('merchant-preview-location')))
            .properties
            .label,
        '营业中');
    await _show(tester, find.byKey(const ValueKey('merchant-tag-mode')));
    await _toggleTagMode(tester);
    await tester.pumpAndSettle();
    for (final label in ['卫生干净', '性价比高']) {
      await _show(tester, find.widgetWithText(FilterChip, label));
      await tester.tap(find.widgetWithText(FilterChip, label));
      await tester.pumpAndSettle();
    }
    expect(previewTags(), ['卫生干净', '性价比高']);
    await _show(tester, find.widgetWithText(FilterChip, '卫生干净'));
    await tester.tap(find.widgetWithText(FilterChip, '卫生干净'));
    await tester.pumpAndSettle();
    expect(previewTags(), ['性价比高']);
    await _show(tester, find.widgetWithText(FilterChip, '味道不错'));
    await tester.tap(find.widgetWithText(FilterChip, '味道不错'));
    await tester.pumpAndSettle();
    expect(previewTags(), ['性价比高', '味道不错']);
    await _show(tester, find.byKey(const ValueKey('merchant-tag-mode')));
    await _toggleTagMode(tester);
    await tester.pumpAndSettle();
    expect(previewTags(), ['味道不错', '分量足', '性价比高']);
  });

  for (final state in ['empty', 'legacy']) {
    testWidgets('自动标签 $state 显示明确状态，不伪造汇总标签', (tester) async {
      final data = {..._tags};
      if (state == 'empty') {
        data['automatic_tags'] = [];
      } else {
        data.remove('automatic_tags');
      }
      final dio = _dio(
          (r) => r.path.endsWith('/display-tags') ? _reply(r, data) : null);
      await _pump(tester, dio,
          AdminCanteenEditorScreen(canteen: Canteen.fromJson(_shop)));
      expect(find.text(state == 'empty' ? '暂无可汇总的评价标签' : '保存后根据近期评价自动更新'),
          findsOneWidget);
      expect(find.byKey(const ValueKey('merchant-tag-preview')), findsNothing);
      expect(
          tester
              .widget<TextButton>(find.byKey(const ValueKey('merchant-submit')))
              .onPressed,
          isNull);
    });
  }

  for (final available in [true, false]) {
    testWidgets('商家封面${available ? '加载成功' : '文件丢失'}不影响资料编辑', (tester) async {
      final requests = <String>[];
      await tester
          .runAsync(() => installMockPublicImageHttp(imageStatus: (uri) {
                requests.add(uri.path);
                return available ? 200 : 404;
              }));
      addTearDown(uninstallMockPublicImageHttp);
      final dio = _dio((_) => null);
      final imagePath =
          '/uploads/editor-cover-${available ? 'available' : 'missing'}.png';
      final shop = Canteen.fromJson({..._shop, 'image': imagePath});
      await _pump(tester, dio, AdminCanteenEditorScreen(canteen: shop));
      await driveMockPublicImageLoads(tester,
          until: () => available
              ? find
                  .byWidgetPredicate(
                      (widget) => widget is RawImage && widget.image != null)
                  .evaluate()
                  .isNotEmpty
              : requests.contains(imagePath));
      await tester.pumpAndSettle();
      if (available) {
        expect(
            find.byWidgetPredicate(
                (widget) => widget is RawImage && widget.image != null),
            findsOneWidget);
        expect(find.byTooltip('暂无封面'), findsNothing);
      } else {
        expect(requests, contains(imagePath));
        expect(find.byTooltip('暂无封面'), findsOneWidget);
      }
      await tester.enterText(find.byType(TextFormField), '封面不影响改名');
      await tester.pump();
      expect(
          tester
              .widget<TextButton>(find.byKey(const ValueKey('merchant-submit')))
              .onPressed,
          isNotNull);
      await tester.pumpWidget(const SizedBox());
      await flushMockPublicImageTimers(tester);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('旧服务没有统一保存能力时阻止误报成功，可退出', (tester) async {
    var writes = 0;
    final dio = _dio((r) {
      if (r.method != 'GET') writes++;
      return r.path == '/canteens/meta'
          ? _reply(r, {
              'location_areas': ['一食堂', '二食堂']
            })
          : null;
    });
    await _pump(
        tester, dio, AdminCanteenEditorScreen(canteen: Canteen.fromJson(_shop)),
        route: true);
    expect(find.text('当前服务尚未支持统一编辑，请更新服务后重试'), findsOneWidget);
    expect(
        tester
            .widget<TextButton>(find.byKey(const ValueKey('merchant-submit')))
            .onPressed,
        isNull);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(AdminCanteenEditorScreen), findsNothing);
    expect(writes, 0);
  });

  for (final status in [401, 403, 404]) {
    testWidgets('编辑加载 $status 不进入可编辑状态', (tester) async {
      final dio = _dio((r) =>
          r.path.endsWith('/display-tags') ? _reply(r, {}, status) : null);
      await _pump(tester, dio,
          AdminCanteenEditorScreen(canteen: Canteen.fromJson(_shop)));
      expect(find.byType(TextFormField), findsNothing);
      expect(
          tester
              .widget<TextButton>(find.byKey(const ValueKey('merchant-submit')))
              .onPressed,
          isNull);
      expect(find.text('重试'), findsOneWidget);
    });
  }

  testWidgets('编辑撤销权限和下架资料只读边界', (tester) async {
    final dio = _dio((_) => null);
    final auth = _Auth(dio);
    await _pump(
        tester, dio, AdminCanteenEditorScreen(canteen: Canteen.fromJson(_shop)),
        auth: auth);
    auth.revoke();
    await tester.pumpAndSettle();
    expect(find.text('账号或管理权限已变更，请返回后重新打开'), findsOneWidget);
    expect(find.byType(TextFormField), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await _pump(tester, dio,
        AdminCanteenEditorScreen(canteen: Canteen.fromJson(_archive)));
    expect(find.byType(TextFormField), findsNothing);
    expect(
        tester
            .widget<TextButton>(find.byKey(const ValueKey('merchant-submit')))
            .onPressed,
        isNull);
  });

  for (final phase in ['load', 'save']) {
    testWidgets('编辑 $phase 晚到响应不能恢复重新登录后的页面或返回成功', (tester) async {
      final pending = Completer<Response<dynamic>>();
      RequestOptions? request;
      final dio = _dio((r) {
        if ((phase == 'load' && r.path.endsWith('/display-tags')) ||
            (phase == 'save' && r.method == 'PATCH')) {
          request = r;
          return pending.future;
        }
        return null;
      });
      final auth = _Auth(dio);
      await _pump(tester, dio,
          AdminCanteenEditorScreen(canteen: Canteen.fromJson(_shop)),
          auth: auth, route: true, settle: phase != 'load');
      if (phase == 'save') {
        await tester.enterText(find.byType(TextFormField), '等待保存');
        await tester.pumpAndSettle();
        await tester.tap(find.text('保存修改'));
      }
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      auth.relogin();
      pending.complete(_reply(request!, phase == 'load' ? _tags : {}));
      await tester.pumpAndSettle();
      expect(find.byType(AdminCanteenEditorScreen), findsOneWidget);
      expect(find.text('账号或管理权限已变更，请返回后重新打开'), findsOneWidget);
      expect(find.byType(TextFormField), findsNothing);
      expect(
          tester
              .widget<TextButton>(find.byKey(const ValueKey('merchant-submit')))
              .onPressed,
          isNull);
    });
  }

  testWidgets('上下架请求防重复，失败保留状态并可重试', (tester) async {
    var writes = 0;
    final pending = Completer<Response<dynamic>>();
    RequestOptions? write;
    final dio = _dio((r) {
      if (r.path == '/canteens/admin-list') {
        return _reply(r, {
          'items': [_shop]
        });
      }
      if (r.path.endsWith('/offline')) {
        writes++;
        write = r;
        return pending.future;
      }
      return null;
    });
    await _pump(tester, dio, const AdminCanteenOperationsScreen());
    await tester.tap(find.byTooltip('管理「川渝椒香」'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下架商家'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认下架'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(
        tester
            .widget<PopupMenuButton<String>>(
                find.byType(PopupMenuButton<String>).last)
            .enabled,
        isFalse);
    pending.complete(_reply(write!, {'error': '暂时无法下架'}, 500));
    await tester.pumpAndSettle();
    expect(writes, 1);
    expect(find.text('营业中 1'), findsOneWidget);
    await tester.tap(find.byTooltip('管理「川渝椒香」'));
    await tester.pumpAndSettle();
    expect(find.text('下架商家'), findsOneWidget);
    expect(find.text('暂时无法下架'), findsOneWidget);
  });

  testWidgets('投稿支持其他无楼层，上传与保存失败恢复，成功只提交一次并返回', (tester) async {
    final picker = _Picker()
      ..file = XFile.fromData(
          base64Decode(
              'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/lWQAAAAASUVORK5CYII='),
          name: 'shop.png',
          mimeType: 'image/png');
    final original = ImagePickerPlatform.instance;
    ImagePickerPlatform.instance = picker;
    addTearDown(() => ImagePickerPlatform.instance = original);
    var uploads = 0, submissions = 0;
    Map<String, dynamic>? sent;
    final pending = Completer<Response<dynamic>>();
    RequestOptions? submit;
    final dio = _dio((r) {
      if (r.path == '/upload') {
        uploads++;
        return uploads == 1
            ? _reply(r, {'message': '上传暂不可用'}, 500)
            : _reply(r, {'file_id': 8, 'url': '/uploads/shop.jpg'});
      }
      if (r.method == 'POST' && r.path == '/canteens') {
        submissions++;
        submit = r;
        sent = Map<String, dynamic>.from(r.data as Map);
        expect(r.extra['expectedAuthSessionEpoch'], 1);
        if (submissions == 1) return _reply(r, {'error': '这家店正在审核中'}, 409);
        return pending.future;
      }
      return null;
    });
    await _pump(tester, dio, const CanteenSubmitScreen(initialName: '校外餐饮'),
        route: true);
    await _chooseArea(tester, '其他');
    expect(find.text('所在楼层'), findsNothing);
    Future<void> pick() async {
      await _show(tester, find.text('添加图片'));
      await tester.tap(find.text('添加图片'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('从相册选择'));
      await tester.pumpAndSettle();
    }

    await pick();
    expect(find.textContaining('上传失败'), findsOneWidget);
    await pick();
    expect(
        find.descendant(
            of: find.byType(ImageUploadWidget), matching: find.byType(Image)),
        findsOneWidget);
    await tester.tap(find.text('提交审核'));
    await tester.pumpAndSettle();
    expect(submissions, 1);
    expect(find.byType(CanteenSubmitScreen), findsOneWidget);
    expect(
        find.descendant(
            of: find.byType(ImageUploadWidget), matching: find.byType(Image)),
        findsOneWidget);
    expect(sent,
        {'name': '校外餐饮', 'image': '/uploads/shop.jpg', 'location_area': '其他'});
    await tester.tap(find.text('提交审核'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('提交中…'));
    await Navigator.of(tester.element(find.byType(CanteenSubmitScreen)))
        .maybePop();
    await tester.pump();
    expect(submissions, 2);
    pending.complete(_reply(submit!, {}, 201));
    await tester.pumpAndSettle();
    expect(find.byType(CanteenSubmitScreen), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('投稿表单验证名称位置图片，离开提醒可继续填写', (tester) async {
    final dio = _dio((_) => null);
    await _pump(tester, dio, const CanteenSubmitScreen(), route: true);
    expect(find.byType(ImageUploadWidget), findsOneWidget);
    await tester.enterText(find.byType(TextFormField), 'a');
    await tester.tap(find.text('提交审核'));
    await tester.pumpAndSettle();
    expect(find.text('商家名称需为 2–100 个字符'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField), '新店铺');
    await tester.tap(find.text('提交审核'));
    await tester.pumpAndSettle();
    expect(find.text('请选择商家所在区域'), findsWidgets);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('放弃本次提交？'), findsOneWidget);
    await tester.tap(find.text('继续填写'));
    await tester.pumpAndSettle();
    expect(find.text('新店铺'), findsOneWidget);
  });

  testWidgets('相册权限拒绝、取消和选择期间重新登录，不产生跨会话上传', (tester) async {
    final original = ImagePickerPlatform.instance;
    final picker = _Picker()..denied = true;
    ImagePickerPlatform.instance = picker;
    addTearDown(() => ImagePickerPlatform.instance = original);
    var uploads = 0;
    final dio = _dio((r) {
      if (r.path == '/upload') uploads++;
      return null;
    });
    final auth = _Auth(dio);
    await _pump(tester, dio, const CanteenSubmitScreen(), auth: auth);
    Future<void> open() async {
      await _show(tester, find.text('添加图片'));
      await tester.tap(find.text('添加图片'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('从相册选择'));
    }

    await open();
    await tester.pumpAndSettle();
    expect(find.text('无法访问相册或相机，请在系统设置中允许权限后重试'), findsOneWidget);
    picker.denied = false;
    await open();
    await tester.pumpAndSettle();
    expect(uploads, 0);
    picker.pending = Completer<XFile?>();
    await open();
    await tester.pump();
    expect(
        tester
            .widget<TextButton>(find.byKey(const ValueKey('merchant-submit')))
            .onPressed,
        isNull);
    auth.relogin();
    await tester.pumpAndSettle();
    picker.pending!.complete(XFile.fromData(
        base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/lWQAAAAASUVORK5CYII='),
        name: 'shop.png',
        mimeType: 'image/png'));
    await tester.pumpAndSettle();
    expect(uploads, 0);
    expect(find.text('登录状态已变更，请返回并重新登录后提交'), findsOneWidget);
  });

  testWidgets('窄屏大字号与键盘下可滚动操作；壁纸沿用共享背景和材质', (tester) async {
    AppPreferencesStore.setMockInitialValues({});
    final appearance = ThemeProvider(loadOnStart: false);
    addTearDown(appearance.dispose);
    await appearance.setBackgroundImage('morenbeijing.jpeg');
    final dio = _dio((r) => r.path == '/canteens/admin-list'
        ? _reply(r, {
            'items': [_shop]
          })
        : null);
    final capture = GlobalKey();
    await _pump(tester, dio, const AdminCanteenOperationsScreen(),
        size: const Size(360, 640),
        scale: 1.8,
        appearance: appearance,
        capture: capture);
    final wallpaper = tester.widget<Image>(find.byType(Image).first).image;
    await tester
        .runAsync(() => precacheImage(wallpaper, capture.currentContext!));
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    addTearDown(tester.view.resetViewInsets);
    await tester.enterText(find.byType(TextField), '川渝');
    await tester.pumpAndSettle();
    await _capture(tester, capture, 'management-keyboard-wallpaper');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await _pump(tester, dio, const CanteenSubmitScreen(),
        size: const Size(360, 640),
        scale: 1.8,
        appearance: appearance,
        capture: capture);
    await tester.enterText(find.byType(TextFormField), '键盘输入');
    await tester.pumpAndSettle();
    await _capture(tester, capture, 'submit-keyboard-wallpaper');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await _pump(
        tester, dio, AdminCanteenEditorScreen(canteen: Canteen.fromJson(_shop)),
        size: const Size(360, 640),
        scale: 1.8,
        appearance: appearance,
        capture: capture,
        route: true);
    await _show(tester, find.byType(TextFormField));
    await tester.enterText(find.byType(TextFormField), '键盘编辑商家');
    await tester.pumpAndSettle();
    final save = find.byKey(const ValueKey('merchant-submit'));
    expect(tester.widget<TextButton>(save).onPressed, isNotNull);
    expect(tester.getBottomRight(save).dy, lessThanOrEqualTo(360));
    await _capture(tester, capture, 'editor-keyboard-wallpaper');
    expect(tester.takeException(), isNull);
  });

  for (final profile in ['light', 'dark', 'large-text', 'tablet']) {
    testWidgets('管理与投稿 $profile 真实渲染', (tester) async {
      final dio = _dio((r) => r.path == '/canteens/admin-list'
          ? _reply(r, {
              'items': [_shop, _other, _archive]
            })
          : null);
      final capture = GlobalKey();
      final theme = profile == 'dark' ? ThemeMode.dark : ThemeMode.light;
      final scale = profile == 'large-text' ? 1.8 : 1.0;
      final size =
          profile == 'tablet' ? const Size(1100, 850) : const Size(390, 844);
      await _pump(tester, dio, const AdminCanteenOperationsScreen(),
          theme: theme, scale: scale, size: size, capture: capture);
      await _capture(tester, capture, 'management-$profile');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await _pump(tester, dio, const CanteenSubmitScreen(initialName: '校外小馆'),
          theme: theme, scale: scale, size: size, capture: capture);
      await _capture(tester, capture, 'submit-$profile');
      await _show(tester, find.text('添加图片'));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await _pump(tester, dio,
          AdminCanteenEditorScreen(canteen: Canteen.fromJson(_shop)),
          theme: theme,
          scale: scale,
          size: size,
          capture: capture,
          route: true);
      await _capture(tester, capture, 'editor-$profile');
      await _show(tester, find.byKey(const ValueKey('merchant-tag-mode')));
      await _toggleTagMode(tester);
      await tester.pumpAndSettle();
      for (final label in ['卫生干净', '性价比高']) {
        final option = find.widgetWithText(FilterChip, label);
        await _show(tester, option);
        await tester.tap(option);
        await tester.pumpAndSettle();
      }
      await _show(tester, find.text('未选择时不显示评价标签'));
      await _capture(tester, capture, 'editor-tags-$profile');
      await tester.drag(
          find.byType(SingleChildScrollView), const Offset(0, 2400));
      await tester.pumpAndSettle();
      await _capture(tester, capture, 'editor-manual-preview-$profile');
      expect(tester.takeException(), isNull);
    });
  }
}

import 'dart:async';
import 'dart:ui';
import 'dart:io' show File;
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:home_widget/home_widget.dart';
import 'package:jpush_flutter/jpush_flutter.dart';
import 'package:provider/provider.dart';
import 'providers/auth_provider.dart';
import 'providers/theme_provider.dart';
import 'providers/post_provider.dart';
import 'providers/message_provider.dart';
import 'providers/edu_provider.dart';
import 'providers/course_schedule_provider.dart';
import 'providers/major_provider.dart';
import 'providers/teacher_provider.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'screens/course_schedule_screen.dart';
import 'services/course_reminder_service.dart';
import 'services/home_widget_service.dart';
import 'theme/AppTheme.dart';
import 'config/api_constants.dart';
import 'utils/app_navigator.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter();
  await CourseReminderService.instance.initialize();
  await HomeWidgetService.initialize();
  runApp(const MyApp());
}

/// 极光推送初始化
var jpush = JPush.newJPush();

Future<void> setupJPush() async {
  jpush.setup(
    appKey: 'fbbd87f741e919f39519afe6',
    channel: 'developer-default',
    production: false,
    debug: true,
  );
  jpush.addEventHandler(
    onReceiveNotification: (Map<String, dynamic> message) async {
      debugPrint('🔔 收到通知: $message');
    },
    onOpenNotification: (Map<String, dynamic> message) async {
      debugPrint('👆 用户点击通知: $message');
    },
  );
  final rid = await jpush.getRegistrationID();
  debugPrint('🔥 JPush RegistrationID: $rid');
  // 获取 auth provider 并更新 token
  // 注意：需要在 AuthWrapper 完成初始化后调用
}

Dio? _sharedDio;

Dio getSharedDio() {
  if (_sharedDio == null) {
    final dio = Dio(BaseOptions(
      baseUrl:
          kDebugMode ? ApiConstants.baseUrl : 'https://sylu.zhouwu.ccwu.cc/api',
      connectTimeout: ApiConstants.connectTimeout,
      receiveTimeout: ApiConstants.receiveTimeout,
    ));

    if (kDebugMode) {
      dio.interceptors.add(LogInterceptor(
        requestBody: true,
        responseBody: true,
        logPrint: (o) => debugPrint(o.toString()),
      ));
    }

    dio.interceptors.add(InterceptorsWrapper(
      onError: (error, handler) {
        debugPrint('DioError [${error.response?.statusCode}]: ${error.requestOptions.uri}');
        handler.next(error);
      },
    ));

    _sharedDio = dio;
  }
  return _sharedDio!;
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final dio = getSharedDio();

    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ChangeNotifierProvider(create: (_) => AuthProvider(dio)),
        ChangeNotifierProvider(create: (_) => PostProvider(dio)),
        ChangeNotifierProvider(create: (_) => MessageProvider(dio)),
        ChangeNotifierProvider(create: (_) => EduProvider(dio)),
        ChangeNotifierProvider(create: (_) => CourseScheduleProvider()),
        ChangeNotifierProvider(create: (_) => TeacherProvider(dio)),
        ChangeNotifierProvider(create: (_) => MajorProvider(dio)),
      ],
      child: const _TimetableDeepLinkHandler(
        child: _AppContent(),
      ),
    );
  }
}

/// 课表小部件深度链接处理器
///
/// 监听 [HomeWidget.widgetClicked] 和 [HomeWidget.initiallyLaunchedFromHomeWidget]，
/// 当检测到 timetable://home URI 时导航到课表页。
class _TimetableDeepLinkHandler extends StatefulWidget {
  final Widget child;
  const _TimetableDeepLinkHandler({required this.child});

  @override
  State<_TimetableDeepLinkHandler> createState() =>
      _TimetableDeepLinkHandlerState();
}

class _TimetableDeepLinkHandlerState extends State<_TimetableDeepLinkHandler> {
  StreamSubscription<Uri?>? _clickSub;

  @override
  void initState() {
    super.initState();
    _setupListeners();
  }

  void _setupListeners() {
    // 监听 widget 点击事件（App 在后台 / 挂起时）
    _clickSub = HomeWidget.widgetClicked.listen(_onWidgetClicked);

    // 冷启动检测
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkInitialLaunch();
    });
  }

  Future<void> _checkInitialLaunch() async {
    try {
      final uri = await HomeWidget.initiallyLaunchedFromHomeWidget();
      if (uri != null && mounted) {
        _handleDeepLink(uri);
      }
    } catch (e) {
      debugPrint('检查初始启动 URI 失败: $e');
    }
  }

  void _onWidgetClicked(Uri? uri) {
    if (uri != null) {
      _handleDeepLink(uri);
    }
  }

  void _handleDeepLink(Uri uri) {
    debugPrint('🔗 收到 widget 深度链接: $uri');
    if (uri.scheme == 'timetable' && uri.host == 'home') {
      _navigateToTimetable();
    }
  }

  void _navigateToTimetable() {
    final navigator = appNavigatorKey.currentState;
    if (navigator == null) {
      // Navigator 尚未就绪，延迟一帧再试
      WidgetsBinding.instance.addPostFrameCallback((_) => _navigateToTimetable());
      return;
    }
    // 如果已在课表页，不重复导航
    final currentRoute = ModalRoute.of(appNavigatorKey.currentContext!);
    if (currentRoute?.settings.name == '/timetable') return;

    // 先 pop 到根路由，再 push 课表页
    navigator.popUntil((route) => route.isFirst);
    navigator.pushNamed('/timetable');
  }

  @override
  void dispose() {
    _clickSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// 抽离 MaterialApp 构建，避免 Consumer 嵌套层级过深
class _AppContent extends StatelessWidget {
  const _AppContent();

  @override
  Widget build(BuildContext context) {
    final themeProvider = context.watch<ThemeProvider>();
    return MaterialApp(
      title: '沈理校园',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: themeProvider.isDarkMode ? ThemeMode.dark : ThemeMode.light,
      navigatorKey: appNavigatorKey,
      routes: {
        '/login': (context) => const LoginScreen(),
        '/timetable': (context) => const PredictiveBackGate(
              child: GlobalBackgroundWrapper(
                child: CourseScheduleScreen(),
              ),
            ),
      },
      home: const PredictiveBackGate(
        child: GlobalBackgroundWrapper(
          child: AuthWrapper(),
        ),
      ),
    );
  }
}

final GlobalKey<_BackgroundWrapperState> backgroundWrapperKey =
    GlobalKey<_BackgroundWrapperState>();

class GlobalBackgroundWrapper extends StatefulWidget {
  final Widget child;

  const GlobalBackgroundWrapper({
    super.key,
    required this.child,
  });

  @override
  State<GlobalBackgroundWrapper> createState() => _BackgroundWrapperState();
}

class _BackgroundWrapperState extends State<GlobalBackgroundWrapper> {
  String _currentScreen = 'shuitie';

  void updateScreen(String screen) {
    if (_currentScreen != screen) {
      setState(() {
        _currentScreen = screen;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = context.watch<ThemeProvider>();
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Stack(
      fit: StackFit.expand,
      children: [
        // Always render background in consistent structure
        _buildBackgroundLayer(themeProvider, isDark),
        // Child content
        widget.child,
      ],
    );
  }

  Widget _buildBackgroundLayer(ThemeProvider themeProvider, bool isDark) {
    final bool showBackground = themeProvider.isBackgroundVisible;

    if (showBackground) {
      return _buildBackgroundImageLayer(themeProvider, isDark);
    } else {
      return _buildDefaultBackground(isDark);
    }
  }

  Widget _buildBackgroundImageLayer(ThemeProvider themeProvider, bool isDark) {
    final bgPath = themeProvider.backgroundImage!;
    final isAsset = !bgPath.startsWith('http') && !bgPath.startsWith('/');
    final resolvedPath = isAsset ? 'assets/images/$bgPath' : bgPath;

    return Stack(
      fit: StackFit.expand,
      children: [
        // Background image
        isAsset
            ? Image.asset(
                resolvedPath,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _buildDefaultBackground(isDark),
              )
            : bgPath.startsWith('/')
                ? Image.file(
                    File(bgPath),
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) =>
                        _buildDefaultBackground(isDark),
                  )
                : Image.network(
                    bgPath,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) =>
                        _buildDefaultBackground(isDark),
                    loadingBuilder: (_, child, loadingProgress) {
                      if (loadingProgress == null) return child;
                      return _buildDefaultBackground(isDark);
                    },
                  ),
        // Color overlay (fixed — componentOpacity controls GlassContainer, not background)
        Container(
          color: isDark
              ? Colors.black.withValues(alpha: 0.35)
              : Colors.white.withValues(alpha: 0.25),
        ),
        // Blur overlay
        if (themeProvider.backgroundBlur > 0 && themeProvider.liquidGlass)
          BackdropFilter(
            filter: ImageFilter.blur(
              sigmaX: themeProvider.backgroundBlur,
              sigmaY: themeProvider.backgroundBlur,
            ),
            child: Container(color: Colors.transparent),
          ),
      ],
    );
  }

  Widget _buildDefaultBackground(bool isDark) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Image(
          image: ResizeImage(
            const AssetImage('assets/images/morenbeijing.jpeg'),
            width: 1080,
          ),
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: isDark
                    ? [
                        const Color(0xFF1A1A2E),
                        const Color(0xFF16213E),
                        const Color(0xFF0F3460)
                      ]
                    : [
                        const Color(0xFF667EEA),
                        const Color(0xFF764BA2),
                        const Color(0xFFF093FB)
                      ],
              ),
            ),
          ),
        ),
        Container(
          color: isDark
              ? Colors.black.withValues(alpha: 0.35)
              : Colors.white.withValues(alpha: 0.25),
        ),
      ],
    );
  }
}

class AuthWrapper extends StatelessWidget {
  const AuthWrapper({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<AuthProvider>(
      builder: (context, authProvider, child) {
        if (!authProvider.isInitialized) {
          return const Scaffold(
            body: Center(
              child: CircularProgressIndicator(),
            ),
          );
        }

        // 未登录用户也直接进入首页（游客模式）
        // 登录状态由各需要认证的页面自行检查
        return const HomeScreen();
      },
    );
  }
}

/// 预测性返回手势开关门控
/// 通过 ThemeProvider.predictiveBack 控制，默认开启
class PredictiveBackGate extends StatelessWidget {
  final Widget child;
  const PredictiveBackGate({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    // 这里不再由全局接管拦截逻辑，而是由子页面按需拦截
    return child;
  }
}

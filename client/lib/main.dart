import 'dart:async';
import 'dart:ui';
import 'dart:io' show File;
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:jpush_flutter/jpush_flutter.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'providers/auth_provider.dart';
import 'providers/theme_provider.dart';
import 'providers/post_provider.dart';
import 'providers/message_provider.dart';
import 'providers/edu_provider.dart';
import 'providers/course_schedule_provider.dart';
import 'providers/major_provider.dart';
import 'providers/teacher_provider.dart';
import 'providers/canteen_provider.dart';

import 'providers/social_provider.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'screens/course_schedule_screen.dart';
import 'screens/exam_schedule_screen.dart';
import 'screens/user_replies_screen.dart';
import 'services/course_reminder_service.dart';
import 'theme/AppTheme.dart';
import 'config/api_constants.dart';
import 'utils/app_navigator.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 强制沉浸式（Edge-to-Edge），解决悬浮底栏下方的系统黑条空挡问题
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    systemNavigationBarColor: Colors.transparent,
    statusBarColor: Colors.transparent,
  ));

  await Hive.initFlutter();
  await CourseReminderService.instance.initialize();
  runApp(const MyApp());
}

/// 极光推送初始化
var jpush = JPush.newJPush();

Future<void> setupJPush(AuthProvider authProvider) async {
  jpush.setup(
    appKey: ApiConstants.jpushAppKey,
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
      if (await _handleUpdateNotification(message)) {
        return;
      }
      if (appNavigatorKey.currentState != null) {
        appNavigatorKey.currentState!.popUntil((route) => route.isFirst);
        appNavigatorKey.currentState!.push(
          MaterialPageRoute(builder: (_) => const UserRepliesScreen()),
        );
      }
    },
  );
  final rid = await jpush.getRegistrationID();
  debugPrint('🔥 JPush RegistrationID: $rid');

  if (rid.isNotEmpty) {
    await authProvider.updateDeviceToken(rid);
    debugPrint('✅ 成功上报 JPush Device Token: $rid');
  }
}

Future<bool> _handleUpdateNotification(Map<String, dynamic> message) async {
  final extras = _extractJPushExtras(message);
  if (extras['type']?.toString() != 'app_update') {
    return false;
  }

  final downloadUrl = extras['download_url']?.toString() ?? '';
  final uri = Uri.tryParse(downloadUrl);
  if (uri == null || !uri.hasScheme || !uri.hasAuthority) {
    debugPrint('更新推送缺少有效下载地址: $message');
    return true;
  }

  try {
    var launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched) {
      launched = await launchUrl(uri, mode: LaunchMode.platformDefault);
    }
    if (!launched) {
      debugPrint('无法打开更新下载地址: $downloadUrl');
    }
  } catch (e) {
    debugPrint('打开更新下载地址失败: $e');
  }
  return true;
}

Map<String, dynamic> _extractJPushExtras(Map<String, dynamic> message) {
  final extras = message['extras'];
  if (extras is Map) {
    return extras.map((key, value) => MapEntry(key.toString(), value));
  }

  final android = message['android'];
  if (android is Map && android['extras'] is Map) {
    final androidExtras = android['extras'] as Map;
    return androidExtras.map((key, value) => MapEntry(key.toString(), value));
  }

  return message.map((key, value) => MapEntry(key.toString(), value));
}

Dio? _sharedDio;

Dio getSharedDio() {
  if (_sharedDio == null) {
    final dio = Dio(BaseOptions(
      baseUrl: ApiConstants.baseUrl,
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
        debugPrint(
            'DioError [${error.response?.statusCode}]: ${error.requestOptions.uri}');
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
        ChangeNotifierProvider(create: (_) => CanteenProvider(dio)),
        ChangeNotifierProvider(create: (_) => SocialProvider(dio)),
      ],
      child: const _WidgetDeepLinkHandler(
        child: _AppContent(),
      ),
    );
  }
}

/// 小组件深度链接处理器
///
/// 点击 widget → MainActivity → MethodChannel → 通知 HomeScreen 切到课表 tab
/// 不 push 新路由，不盖住现有页面。
class _WidgetDeepLinkHandler extends StatefulWidget {
  final Widget child;
  const _WidgetDeepLinkHandler({required this.child});

  @override
  State<_WidgetDeepLinkHandler> createState() => _WidgetDeepLinkHandlerState();
}

class _WidgetDeepLinkHandlerState extends State<_WidgetDeepLinkHandler>
    with WidgetsBindingObserver {
  static const _channel = MethodChannel('shenliyuan/deeplink');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkDeepLink());

    // 监听原生端主动推送的深度链接（瞬间响应，避免打断动画）
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onDeepLink') {
        final uri = call.arguments as String?;
        if ((uri == 'widget_timetable' || uri == 'campus://timetable') &&
            mounted) {
          appNavigatorKey.currentState?.popUntil((route) => route.isFirst);
          widgetTabSwitch.value++;
        } else if (uri != null && uri.startsWith('widget_exam') && mounted) {
          appNavigatorKey.currentState?.popUntil((route) => route.isFirst);
          appNavigatorKey.currentState?.push(
              MaterialPageRoute(builder: (_) => const ExamScheduleScreen()));
        }
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkDeepLink();
    }
  }

  Future<void> _checkDeepLink() async {
    try {
      final uri = await _channel.invokeMethod<String>('getPendingDeepLink');
      if ((uri == 'widget_timetable' || uri == 'campus://timetable') &&
          mounted) {
        appNavigatorKey.currentState?.popUntil((route) => route.isFirst);
        // 切换到底部导航的课程表 tab，不 push 新页面
        widgetTabSwitch.value++;
      } else if (uri != null && uri.startsWith('widget_exam') && mounted) {
        appNavigatorKey.currentState?.popUntil((route) => route.isFirst);
        appNavigatorKey.currentState?.push(
            MaterialPageRoute(builder: (_) => const ExamScheduleScreen()));
      }
    } catch (e) {
      debugPrint('深度链接检查失败: $e');
    }
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
      theme: AppTheme.lightTheme.copyWith(
        pageTransitionsTheme: PageTransitionsTheme(
          builders: {
            TargetPlatform.android: themeProvider.predictiveBack
                ? const PredictiveBackPageTransitionsBuilder()
                : const FadeUpwardsPageTransitionsBuilder(),
          },
        ),
      ),
      darkTheme: AppTheme.darkTheme.copyWith(
        pageTransitionsTheme: PageTransitionsTheme(
          builders: {
            TargetPlatform.android: themeProvider.predictiveBack
                ? const PredictiveBackPageTransitionsBuilder()
                : const FadeUpwardsPageTransitionsBuilder(),
          },
        ),
      ),
      themeMode: themeProvider.isDarkMode ? ThemeMode.dark : ThemeMode.light,
      navigatorKey: appNavigatorKey,
      scaffoldMessengerKey: scaffoldMessengerKey,
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

final GlobalKey<BackgroundWrapperState> backgroundWrapperKey =
    GlobalKey<BackgroundWrapperState>();

class GlobalBackgroundWrapper extends StatefulWidget {
  final Widget child;

  const GlobalBackgroundWrapper({
    super.key,
    required this.child,
  });

  @override
  State<GlobalBackgroundWrapper> createState() => BackgroundWrapperState();
}

class BackgroundWrapperState extends State<GlobalBackgroundWrapper> {
  String _currentScreen = 'shuitie';

  void updateScreen(String screen) {
    if (_currentScreen != screen) {
      if (mounted) {
        setState(() {
          _currentScreen = screen;
        });
      }
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
    String? bgPath = themeProvider.getBackgroundImageFor(context);
    if (bgPath == null) return _buildDefaultBackground(isDark);
    final isAsset = !bgPath.startsWith('http') && !bgPath.startsWith('/');
    final resolvedPath = isAsset ? 'assets/images/$bgPath' : bgPath;

    const alignment = Alignment.center;
    final fillScreen = themeProvider.getBackgroundFillScreenFor(context);

    final imageProvider = isAsset
        ? AssetImage(resolvedPath) as ImageProvider
        : bgPath.startsWith('/')
            ? FileImage(File(bgPath)) as ImageProvider
            : NetworkImage(bgPath) as ImageProvider;
    return Stack(
      fit: StackFit.expand,
      children: [
        _buildBackgroundImage(
          imageProvider: imageProvider,
          alignment: alignment,
          isDark: isDark,
          fillScreen: fillScreen,
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

  Widget _buildBackgroundImage({
    required ImageProvider imageProvider,
    required Alignment alignment,
    required bool isDark,
    required bool fillScreen,
  }) {
    if (fillScreen) {
      return Image(
        image: imageProvider,
        fit: BoxFit.cover,
        alignment: alignment,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => Container(
          color: isDark ? const Color(0xFF131720) : const Color(0xFFF4F6FB),
        ),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        Transform.scale(
          scale: 1.06,
          child: ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: Image(
              image: imageProvider,
              fit: BoxFit.cover,
              alignment: alignment,
              gaplessPlayback: true,
              errorBuilder: (_, __, ___) => Container(
                color:
                    isDark ? const Color(0xFF131720) : const Color(0xFFF4F6FB),
              ),
            ),
          ),
        ),
        Image(
          image: imageProvider,
          fit: BoxFit.contain,
          alignment: alignment,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
        ),
      ],
    );
  }

  Widget _buildDefaultBackground(bool isDark) {
    final isWide =
        MediaQuery.of(context).size.width > MediaQuery.of(context).size.height;
    final defaultImage = isWide
        ? 'assets/images/tablet_default_landscape.png'
        : 'assets/images/morenbeijing.jpeg';
    return Stack(
      fit: StackFit.expand,
      children: [
        _buildBackgroundImage(
          imageProvider: AssetImage(defaultImage),
          alignment: Alignment.center,
          isDark: isDark,
          fillScreen: false,
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

class AuthWrapper extends StatefulWidget {
  const AuthWrapper({super.key});

  @override
  State<AuthWrapper> createState() => _AuthWrapperState();
}

class _AuthWrapperState extends State<AuthWrapper> {
  bool _jpushSetup = false;

  @override
  Widget build(BuildContext context) {
    return Consumer<AuthProvider>(
      builder: (context, authProvider, child) {
        if (!authProvider.isInitialized) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        if (authProvider.isLoggedIn && !_jpushSetup) {
          _jpushSetup = true;
          setupJPush(authProvider);
        }

        final tp = context.watch<ThemeProvider>();
        return HomeScreen(initialTab: tp.startOnTimetable ? 2 : 0);
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

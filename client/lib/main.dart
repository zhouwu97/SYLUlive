import 'dart:ui';
import 'dart:io' show File;
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
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
import 'services/course_reminder_service.dart';
import 'theme/AppTheme.dart';
import 'config/api_constants.dart';
import 'utils/app_navigator.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter();
  await CourseReminderService.instance.initialize();
  runApp(const MyApp());
}

Dio? _sharedDio;

Dio getSharedDio() {
  if (_sharedDio == null) {
    final dio = Dio(BaseOptions(
      baseUrl:
          kDebugMode ? ApiConstants.baseUrl : 'http://156.233.229.232:8080/api',
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
      child: Consumer<ThemeProvider>(
        builder: (context, themeProvider, child) {
          return MaterialApp(
            title: '沈理校园',
            debugShowCheckedModeBanner: false,
            theme: AppTheme.lightTheme,
            darkTheme: AppTheme.darkTheme,
            themeMode:
                themeProvider.isDarkMode ? ThemeMode.dark : ThemeMode.light,
            navigatorKey: appNavigatorKey,
            routes: {
              '/login': (context) => const LoginScreen(),
            },
            home: const PredictiveBackGate(
              child: GlobalBackgroundWrapper(
                child: AuthWrapper(),
              ),
            ),
          );
        },
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
    final enabled = context.watch<ThemeProvider>().predictiveBack;
    return PopScope(
      canPop: !enabled, // 关闭时 canPop=false，系统返回手势被阻止
      child: child,
    );
  }
}

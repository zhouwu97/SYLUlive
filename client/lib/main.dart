import 'dart:ui';
import 'dart:io' show File;
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'providers/auth_provider.dart';
import 'providers/theme_provider.dart';
import 'providers/post_provider.dart';
import 'providers/message_provider.dart';
import 'providers/edu_provider.dart';
import 'screens/login_screen.dart';
import 'screens/home_screen.dart';
import 'theme/AppTheme.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final dio = Dio(BaseOptions(
      baseUrl: 'https://nominalistically-subpeduncled-alexandria.ngrok-free.dev/api',
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 30),
    ));

    dio.interceptors.add(LogInterceptor(
      requestBody: true,
      responseBody: true,
      logPrint: (o) => debugPrint(o.toString()),
    ));

    dio.interceptors.add(InterceptorsWrapper(
      onError: (error, handler) {
        debugPrint('DioError: ${error.message}');
        if (error.response?.statusCode == 401) {
          debugPrint('登录已过期，请重新登录');
        }
        handler.next(error);
      },
    ));

    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ChangeNotifierProvider(create: (_) => AuthProvider(dio)),
        ChangeNotifierProvider(create: (_) => PostProvider(dio)),
        ChangeNotifierProvider(create: (_) => MessageProvider(dio)),
        ChangeNotifierProvider(create: (_) => EduProvider(dio)),
      ],
      child: Consumer<ThemeProvider>(
        builder: (context, themeProvider, child) {
          return MaterialApp(
            title: '沈理校园',
            debugShowCheckedModeBanner: false,
            theme: AppTheme.lightTheme,
            darkTheme: AppTheme.darkTheme,
            themeMode: themeProvider.isDarkMode ? ThemeMode.dark : ThemeMode.light,
            home: GlobalBackgroundWrapper(
              child: const AuthWrapper(),
            ),
          );
        },
      ),
    );
  }
}

final GlobalKey<_BackgroundWrapperState> backgroundWrapperKey = GlobalKey<_BackgroundWrapperState>();

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
      children: [
        _buildBackground(themeProvider, isDark),
        widget.child,
      ],
    );
  }

  Widget _buildBackground(ThemeProvider themeProvider, bool isDark) {
    if (!themeProvider.isBackgroundVisible(_currentScreen)) {
      return _buildDefaultBackground(isDark);
    }

    final transparency = themeProvider.backgroundTransparency;
    final bgPath = themeProvider.backgroundImage!;
    final isAsset = !bgPath.startsWith('http') && !bgPath.startsWith('/');
    final resolvedPath = isAsset ? 'assets/images/$bgPath' : bgPath;

    return Stack(
      fit: StackFit.expand,
      children: [
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
                    errorBuilder: (_, __, ___) => _buildDefaultBackground(isDark),
                  )
                : Image.network(
                    bgPath,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => _buildDefaultBackground(isDark),
                    loadingBuilder: (_, __, ___) => _buildDefaultBackground(isDark),
                  ),
        Container(
          color: isDark
              ? Colors.black.withValues(alpha: transparency)
              : Colors.white.withValues(alpha: transparency),
        ),
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
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? [
                  const Color(0xFF1A1A2E),
                  const Color(0xFF16213E),
                  const Color(0xFF0F3460),
                ]
              : [
                  const Color(0xFF667EEA),
                  const Color(0xFF764BA2),
                  const Color(0xFFF093FB),
                ],
        ),
      ),
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

        return const HomeScreen();
      },
    );
  }
}
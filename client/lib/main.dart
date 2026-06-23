import 'dart:async';
import 'dart:ui';
import 'dart:io' show File;
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
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
import 'models/user.dart';
import 'screens/chat_detail_screen.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'screens/course_schedule_screen.dart';
import 'screens/exam_schedule_screen.dart';
import 'screens/user_replies_screen.dart';
import 'services/course_reminder_service.dart';
import 'theme/AppTheme.dart';
import 'config/api_constants.dart';
import 'utils/app_navigator.dart';
import 'utils/private_message_notification.dart';
import 'services/diagnostic_log_service.dart';
import 'package:crypto/crypto.dart';
import 'dart:convert';

String _hashError(String level, String source, String type, String summary, String detail) {
  final bytes = utf8.encode('$level$source$type$summary$detail');
  return md5.convert(bytes).toString();
}

final Map<String, int> _dedupTimes = {};

void _safeRecord({
  required String level,
  required String source,
  required String type,
  required String summary,
  required String detail,
  required String dedupKey,
  required int dedupMs,
}) {
  final now = DateTime.now().millisecondsSinceEpoch;
  final lastTime = _dedupTimes[dedupKey] ?? 0;
  
  if (now - lastTime < dedupMs) {
    return; // Deduplicate
  }
  _dedupTimes[dedupKey] = now;
  
  // Clean up old entries to prevent memory leak
  if (_dedupTimes.length > 100) {
    _dedupTimes.removeWhere((_, time) => now - time > 60 * 60 * 1000);
  }

  if (level == 'warning') {
    DiagnosticLogService.instance.record(
      level: 'warning',
      source: source,
      type: type,
      summary: summary,
      detail: detail,
    );
  } else {
    DiagnosticLogService.instance.recordError(
      source: source,
      type: type,
      summary: summary,
      detail: detail,
    );
  }
}

Future<void> main() async {
  await runZonedGuarded<Future<void>>(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      FlutterError.onError = (FlutterErrorDetails details) {
        FlutterError.presentError(details);

        final exceptionText = details.exceptionAsString();

        if (exceptionText.contains('_ClientSocketException') &&
            details.library == 'image resource service') {
          
          final hostMatch = RegExp(r'address\s*=\s*([^\s,:]+)').firstMatch(exceptionText);
          final host = hostMatch?.group(1) ?? 'unknown';
          
          _safeRecord(
            level: 'warning',
            source: '图片',
            type: '图片加载失败',
            summary: '图片连接被中途断开',
            detail: exceptionText,
            dedupKey: 'image_error_$host',
            dedupMs: 10 * 60 * 1000, // 10 minutes
          );
          return;
        }

        final fullString = details.toString();
        _safeRecord(
          level: 'error',
          source: 'Flutter',
          type: details.exception.runtimeType.toString(),
          summary: exceptionText,
          detail: fullString,
          dedupKey: _hashError('error', 'Flutter', details.exception.runtimeType.toString(), exceptionText, fullString),
          dedupMs: 2000,
        );
      };

      PlatformDispatcher.instance.onError = (error, stack) {
        final exceptionText = error.toString();
        final fullString = '$error\n\n$stack';

        _safeRecord(
          level: 'error',
          source: 'Flutter',
          type: error.runtimeType.toString(),
          summary: exceptionText,
          detail: fullString,
          dedupKey: _hashError('error', 'Flutter', error.runtimeType.toString(), exceptionText, fullString),
          dedupMs: 2000,
        );
        return true;
      };

      // 强制沉浸式（Edge-to-Edge），解决悬浮底栏下方的系统黑条空挡问题
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
        systemNavigationBarColor: Colors.transparent,
        statusBarColor: Colors.transparent,
      ));

      await Hive.initFlutter();
      await CourseReminderService.instance.initialize();
      await _initializePrivateMessageNotifications();
      runApp(const MyApp());
    },
    (error, stack) {
      final exceptionText = error.toString();
      final fullString = '$error\n\n$stack';
      _safeRecord(
        level: 'error',
        source: 'Dart',
        type: error.runtimeType.toString(),
        summary: exceptionText,
        detail: fullString,
        dedupKey: _hashError('error', 'Dart', error.runtimeType.toString(), exceptionText, fullString),
        dedupMs: 2000,
      );
    },
  );
}

/// 极光推送初始化
var jpush = JPush.newJPush();
final FlutterLocalNotificationsPlugin _privateMessageNotifications =
    FlutterLocalNotificationsPlugin();
bool _privateMessageNotificationsReady = false;
const MethodChannel _privateMessageNotificationChannel =
    MethodChannel('shenliyuan/private_message_notifications');

/// 冷启动时通知数据临时存放（navigator 未就绪前）
final PendingPrivateMessageOpen _pendingPrivateMessageOpen =
    PendingPrivateMessageOpen();

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
      await _handlePrivateMessageNotification(message, opened: false);
    },
    onNotifyMessageUnShow: (Map<String, dynamic> message) async {
      debugPrint('🔕 通知已被原生拦截: $message');
      await _handlePrivateMessageNotification(message, opened: false);
    },
    onOpenNotification: (Map<String, dynamic> message) async {
      debugPrint('👆 点击通知原始数据: $message');
      if (await _handleUpdateNotification(message)) return;
      if (await _handlePrivateMessageNotification(message, opened: true)) {
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
  final userId = authProvider.user?.id;
  if (userId != null) {
    try {
      await jpush.setAlias(userId.toString());
      debugPrint('✅ 成功设置 JPush Alias: $userId');
    } catch (e) {
      debugPrint('设置 JPush Alias 失败: $e');
    }
  }
}

Future<void> _initializePrivateMessageNotifications() async {
  if (_privateMessageNotificationsReady) return;
  const android = AndroidInitializationSettings('@mipmap/ic_launcher');
  const darwin = DarwinInitializationSettings(
    requestAlertPermission: false,
    requestBadgePermission: false,
    requestSoundPermission: false,
  );
  const settings = InitializationSettings(android: android, iOS: darwin);
  await _privateMessageNotifications.initialize(
    settings,
    onDidReceiveNotificationResponse: (response) {
      final payload = response.payload;
      if (payload == null || payload.isEmpty) return;
      try {
        final target = privateMessageTargetFromLocalPayload(payload);
        if (target != null) {
          _clearPrivateMessageNotifications(target.conversationId).ignore();
          _openPrivateMessage(target);
        }
      } catch (e) {
        debugPrint('解析私信本地通知 payload 失败: $e');
      }
    },
  );
  await _privateMessageNotifications
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(
        const AndroidNotificationChannel(
          'developer-default',
          '系统通知',
          description: '评论、系统通知等',
          importance: Importance.low,
        ),
      );
  await _privateMessageNotifications
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(
        const AndroidNotificationChannel(
          'private_messages',
          '私信通知',
          description: '收到新私信时悬浮提醒',
          importance: Importance.high,
        ),
      );
  // Android 13+ 运行时通知权限
  await _privateMessageNotifications
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.requestNotificationsPermission();
  _privateMessageNotificationsReady = true;
}

/// 首帧后请求通知权限（需要 Activity 已创建）
Future<void> _requestNotificationPermissionIfNeeded() async {
  try {
    final plugin =
        _privateMessageNotifications.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    if (plugin == null) return;
    final granted = await plugin.requestNotificationsPermission();
    debugPrint('通知权限请求结果: $granted');
  } catch (e) {
    debugPrint('请求通知权限失败: $e');
  }
}

Future<bool> _handlePrivateMessageNotification(
  Map<String, dynamic> message, {
  required bool opened,
}) async {
  final extras = extractJPushExtras(message);
  debugPrint('📨 解析后extras: $extras');
  if (extras['type']?.toString() != 'private_message') {
    return false;
  }

  final target = privateMessageTargetFromJPushMessage(message);
  if (target == null) {
    debugPrint('私信推送缺少 conversation_id 或 sender_id: $message');
    return true;
  }

  if (opened) {
    await _clearPrivateMessageNotifications(target.conversationId);
    _openPrivateMessage(target);
    return true;
  }

  // 前台不做本地弹窗，全部交给极光 SDK 显示，避免双通知
  final context = appNavigatorKey.currentContext;
  final provider = context?.read<MessageProvider>();
  if (provider?.currentConversationId == target.conversationId) {
    await _clearPrivateMessageNotifications(target.conversationId);
    await provider?.refreshMessages();
    await provider?.markRead(target.conversationId);
  } else {
    await provider?.loadConversations(silent: true);
  }
  return true;
}

Future<void> _clearPrivateMessageNotifications(int conversationId) async {
  try {
    await _privateMessageNotificationChannel.invokeMethod(
      'clearConversationNotifications',
      {'conversationId': conversationId},
    );
  } catch (e) {
    debugPrint('清理私信通知失败: $e');
  }
}

void _openPrivateMessage(PrivateMessageTarget target) {
  // 尝试拉起 App
  const channel = MethodChannel('shenliyuan/foreground');
  channel.invokeMethod('bringToForeground').catchError((e) {});

  final navigator = appNavigatorKey.currentState;
  if (navigator == null) {
    _pendingPrivateMessageOpen.store(target);
    debugPrint(
      '📌 冷启动缓冲通知跳转: conv=${target.conversationId} sender=${target.senderId}',
    );
    return;
  }
  debugPrint('🚪 navigator已就绪，直接跳转');
  _navigateToPrivateMessage(target);
}

void _navigateToPrivateMessage(PrivateMessageTarget target) {
  final navigator = appNavigatorKey.currentState;
  if (navigator == null) {
    debugPrint('❌ navigate: navigator is null');
    return;
  }
  final resolvedTarget = _resolvePrivateMessageTarget(target);
  debugPrint(
    '🧭 navigate: popUntil+push conv=${resolvedTarget.conversationId} sender=${resolvedTarget.senderId}',
  );
  try {
    navigator.popUntil((route) => route.isFirst);
    navigator.push(
      MaterialPageRoute(
        builder: (_) => ChatDetailScreen(
          conversationId: resolvedTarget.conversationId,
          initialMessageId: resolvedTarget.messageId,
          targetUser: User(
            id: resolvedTarget.senderId,
            studentId: '',
            nickname: resolvedTarget.displayName,
            avatar: resolvedTarget.senderAvatar,
            createdAt: DateTime.now(),
          ),
        ),
      ),
    );
    debugPrint('✅ navigate: push 成功');
  } catch (e) {
    debugPrint('❌ navigate: push 失败 - $e');
  }
}

PrivateMessageTarget _resolvePrivateMessageTarget(PrivateMessageTarget target) {
  final context = appNavigatorKey.currentContext;
  final authProvider = context?.read<AuthProvider>();
  final messageProvider = context?.read<MessageProvider>();
  final currentUserId = authProvider?.user?.id;
  if (currentUserId == null || messageProvider == null) return target;

  for (final conversation in messageProvider.conversations) {
    if (conversation.id != target.conversationId) continue;
    final user = conversation.getOtherUser(currentUserId);
    if (user == null) break;
    return target.copyWith(
      senderName: user.nickname.isNotEmpty ? user.nickname : target.senderName,
      senderAvatar: user.avatar.isNotEmpty ? user.avatar : target.senderAvatar,
    );
  }
  return target;
}

void _processPendingOpenNotification() {
  final now = DateTime.now();
  _pendingPrivateMessageOpen.markReady(now);
  if (appNavigatorKey.currentState == null) {
    debugPrint('📌 等待 navigator 就绪后再处理私信通知');
    return;
  }
  final target = _pendingPrivateMessageOpen.consume(now);
  if (target != null) {
    debugPrint(
      '✅ 处理缓冲通知: conv=${target.conversationId} sender=${target.senderId}',
    );
    _navigateToPrivateMessage(target);
  }
}

Future<bool> _handleUpdateNotification(Map<String, dynamic> message) async {
  final extras = extractJPushExtras(message);
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

Dio? _sharedDio;

Dio getSharedDio() {
  if (_sharedDio == null) {
    final dio = Dio(BaseOptions(
      baseUrl: ApiConstants.baseUrl,
      connectTimeout: ApiConstants.connectTimeout,
      receiveTimeout: ApiConstants.receiveTimeout,
      sendTimeout: ApiConstants.sendTimeout,
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
        ChangeNotifierProvider(create: (_) => CourseScheduleProvider(dio)),
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
    final isAsset = ThemeProvider.isBundledAssetBackground(bgPath);
    final isLocalFile = ThemeProvider.isLocalFileBackground(bgPath);
    final resolvedPath =
        isAsset ? ThemeProvider.resolveBundledAssetPath(bgPath) : bgPath;

    const alignment = Alignment.center;
    final fillScreen = themeProvider.getBackgroundFillScreenFor(context);

    final imageProvider = isAsset
        ? AssetImage(resolvedPath) as ImageProvider
        : isLocalFile
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

class _AuthWrapperState extends State<AuthWrapper> with WidgetsBindingObserver {
  bool _jpushSetup = false;
  bool _jpushSettingUp = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      final authProvider = context.read<AuthProvider>();
      if (authProvider.isLoggedIn) {
        _ensureJPush(authProvider);
        _checkNativePrivateMessage();
      }
    }
  }

  bool _checkingNativePrivateMessage = false;

  Future<void> _checkNativePrivateMessage() async {
    if (_checkingNativePrivateMessage) return;
    _checkingNativePrivateMessage = true;

    try {
      final payload =
          await _privateMessageNotificationChannel.invokeMethod<String>(
        'getPendingPrivateMessage',
      );

      if (payload == null || payload.isEmpty) return;

      final target = privateMessageTargetFromLocalPayload(payload);
      if (target == null) {
        debugPrint('原生私信通知参数解析失败: $payload');
        return;
      }

      await _clearPrivateMessageNotifications(target.conversationId);
      _openPrivateMessage(target);
    } catch (e) {
      debugPrint('读取原生待处理私信失败: $e');
    } finally {
      _checkingNativePrivateMessage = false;
    }
  }

  Future<void> _ensureJPush(AuthProvider authProvider) async {
    if (_jpushSetup || _jpushSettingUp) return;

    _jpushSettingUp = true;
    try {
      await setupJPush(authProvider);
      _jpushSetup = true;
      debugPrint('✅ JPush 初始化成功');
    } catch (e, stack) {
      debugPrint('JPush 初始化失败，将在下次恢复时重试: $e');
      debugPrintStack(stackTrace: stack);
    } finally {
      _jpushSettingUp = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AuthProvider>(
      builder: (context, authProvider, child) {
        if (!authProvider.isInitialized) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        if (authProvider.isLoggedIn) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!_jpushSetup && !_jpushSettingUp) {
              _ensureJPush(authProvider);
              _requestNotificationPermissionIfNeeded();
              _processPendingOpenNotification();
            }
            _checkNativePrivateMessage();
          });
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

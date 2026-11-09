import 'package:flutter/material.dart';

import '../utils/app_navigator.dart';
import 'global_background_wrapper.dart';

/// 沿用信息流的 380 / 460 分栏；已在详情栏内的页面继续使用局部导航。
class AdaptiveDetailLayout extends StatefulWidget {
  const AdaptiveDetailLayout({
    super.key,
    required this.master,
    required this.navigationScope,
    required this.isActive,
    this.embedded = false,
    this.expandMasterWhenEmpty = false,
    this.paneKeyPrefix = 'profile',
    this.emptyDetail,
  });

  final Widget master;
  final Object navigationScope;
  final bool isActive;
  final bool embedded;
  final bool expandMasterWhenEmpty;
  final String paneKeyPrefix;
  final Widget? emptyDetail;

  @override
  State<AdaptiveDetailLayout> createState() => AdaptiveDetailLayoutState();
}

class AdaptiveDetailLayoutState extends State<AdaptiveDetailLayout> {
  GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  HeroController _heroController = HeroController();
  late _DetailRouteObserver _observer = _createObserver();
  bool _split = false;
  bool _initialized = false;
  bool _opening = false;

  _DetailRouteObserver _createObserver() {
    final key = _navigatorKey;
    return _DetailRouteObserver(() {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && identical(key, _navigatorKey)) setState(() {});
      });
    });
  }

  @override
  void didUpdateWidget(covariant AdaptiveDetailLayout oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.navigationScope != widget.navigationScope) {
      // 账号、会话或角色变化时销毁旧页面，不能把旧表单带入新权限范围。
      _navigatorKey = GlobalKey<NavigatorState>();
      _heroController = HeroController();
      _observer = _createObserver();
      _opening = false;
    }
  }

  Future<T?> open<T extends Object?>(Route<T> route) async {
    if (!widget.embedded && !_split && !_observer.hasDetail) {
      return Navigator.of(context).push(route);
    }
    final navigator = _navigatorKey.currentState;
    if (navigator == null || _opening) return null;
    _opening = true;
    final scope = widget.navigationScope;
    late Future<T?> result;
    try {
      // 左侧切换入口替换整条详情栈；尊重页面阻止离开的 PopScope。
      while (_observer.hasDetail) {
        final previousTop = _observer.top;
        final handled = await navigator.maybePop();
        if (!mounted || scope != widget.navigationScope) return null;
        if (!handled || identical(previousTop, _observer.top)) return null;
      }
      if (!mounted || scope != widget.navigationScope) return null;
      FocusManager.instance.primaryFocus?.unfocus();
      result = navigator.push(route);
    } finally {
      if (scope == widget.navigationScope) _opening = false;
    }
    return result;
  }

  Route<dynamic>? _generateRoute(RouteSettings settings) {
    if (settings.name != Navigator.defaultRouteName) {
      return Navigator.of(context, rootNavigator: true)
          .widget
          .onGenerateRoute
          ?.call(settings);
    }
    return MaterialPageRoute<void>(
      settings: settings,
      builder: (context) {
        if (widget.emptyDetail != null) return widget.emptyDetail!;
        final colors = Theme.of(context).colorScheme;
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.person_outline_rounded,
                    size: 80, color: colors.onSurface.withValues(alpha: .2)),
                const SizedBox(height: 16),
                Text('选择左侧功能查看详情',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: colors.onSurfaceVariant)),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      _split = !widget.embedded && constraints.maxWidth >= 840;
      _initialized = _initialized || _split || widget.embedded;
      final hasDetail = _observer.hasDetail;
      final showDetail = hasDetail || !widget.expandMasterWhenEmpty;
      final masterWidth = _split && showDetail ? 380.0 : constraints.maxWidth;
      // 两栏的位置和 Element 路径稳定，旋转/分屏时保留详情草稿与滚动。
      return Stack(children: [
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: masterWidth,
          child: Offstage(
            offstage: !_split && hasDetail,
            child: SizedBox.expand(
              key: ValueKey('${widget.paneKeyPrefix}-master-pane'),
              child: widget.master,
            ),
          ),
        ),
        if (_initialized)
          Positioned(
            left: _split ? 380 : 0,
            top: 0,
            right: 0,
            bottom: 0,
            child: Offstage(
              offstage: !hasDetail && (!_split || !showDetail),
              // 局部路由的 BlockSemantics 只作用于右栏，保留左栏的读屏入口。
              child: Semantics(
                container: true,
                explicitChildNodes: true,
                child: ClipRect(
                  key: ValueKey('${widget.paneKeyPrefix}-detail-pane'),
                  child: NavigatorPopHandler<Object?>(
                    enabled: widget.isActive,
                    onPopWithResult: (result) {
                      if (widget.isActive) {
                        _navigatorKey.currentState?.maybePop(result);
                      }
                    },
                    child: HeroControllerScope(
                      controller: _heroController,
                      child: SharedPageBackground(
                        child: ScaffoldMessenger(
                          child: Navigator(
                            key: _navigatorKey,
                            observers: [_observer],
                            onGenerateRoute: _generateRoute,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ]);
    });
  }
}

class _DetailRouteObserver extends NavigatorObserver {
  _DetailRouteObserver(this.onChanged);
  final VoidCallback onChanged;
  final List<Route<dynamic>> _routes = [];
  bool get hasDetail => _routes.length > 1;
  Route<dynamic>? get top => _routes.lastOrNull;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.add(route);
    appRouteObserver.didPush(route, previousRoute);
    onChanged();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    appRouteObserver.didPop(route, previousRoute);
    onChanged();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    appRouteObserver.didRemove(route, previousRoute);
    onChanged();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final index = oldRoute == null ? -1 : _routes.indexOf(oldRoute);
    if (index >= 0) {
      if (newRoute == null) {
        _routes.removeAt(index);
      } else {
        _routes[index] = newRoute;
      }
    }
    appRouteObserver.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    onChanged();
  }
}

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import '../../providers/theme_provider.dart';
import '../../theme/app_theme_tokens.dart';
import '../../utils/app_navigator.dart';

/// 协调来自系统文件关联的 .sltheme 打开事件，阻止迟到的旧请求覆盖新主题并负责回收受管临时副本。
class ThemeIncomingRequest {
  const ThemeIncomingRequest({
    required this.generation,
    required this.eventId,
    this.filePath,
    this.errorCode,
  });

  final int generation;
  final String eventId;
  final String? filePath;
  final String? errorCode;
}

class ThemeIncomingCoordinator extends ChangeNotifier {
  ThemeIncomingCoordinator._();
  static final ThemeIncomingCoordinator instance = ThemeIncomingCoordinator._();

  int _generation = 0;
  ThemeIncomingRequest? _current;
  Object? _activeOwner;

  int get generation => _generation;
  ThemeIncomingRequest? get current => _current;
  bool get hasActiveOwner => _activeOwner != null;

  void claimOwner(Object owner) {
    _activeOwner = owner;
  }

  bool isOwner(Object owner) => identical(_activeOwner, owner);

  void releaseOwner(Object owner, {int? generation}) {
    if (identical(_activeOwner, owner)) {
      _activeOwner = null;
    }
    if (generation != null) {
      clearIfMatches(generation);
    }
  }

  ThemeIncomingRequest accept({
    required String eventId,
    String? filePath,
    String? errorCode,
  }) {
    final previousPath = _current?.filePath;
    final next = ThemeIncomingRequest(
      generation: ++_generation,
      eventId: eventId,
      filePath: filePath,
      errorCode: errorCode,
    );
    _current = next;
    if (previousPath != null && previousPath != filePath) {
      unawaited(cleanupFile(previousPath));
    }
    notifyListeners();
    return next;
  }

  void clearIfMatches(int generation, {bool deleteFile = true}) {
    final active = _current;
    if (active == null || active.generation != generation) return;
    _current = null;
    if (deleteFile && active.filePath != null) {
      unawaited(cleanupFile(active.filePath!));
    }
  }

  static bool isManagedIncomingPath(String filePath) {
    final normalized = path.normalize(filePath);
    return path.split(normalized).contains('incoming-theme');
  }

  static Future<void> cleanupFile(String filePath) async {
    if (!isManagedIncomingPath(filePath)) return;
    try {
      final file = File(filePath);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }
}

/// 全局试用会话顶部常驻状态栏。无试用时直接透传子树，不改变原有布局和间距。
class ThemeTrialBannerHost extends StatefulWidget {
  const ThemeTrialBannerHost({super.key, required this.child});
  final Widget child;

  @override
  State<ThemeTrialBannerHost> createState() => _ThemeTrialBannerHostState();
}

class _ThemeTrialBannerHostState extends State<ThemeTrialBannerHost> {
  bool _busy = false;

  Future<void> _apply(ThemeProvider provider) async {
    if (_busy) return;
    setState(() => _busy = true);
    final messenger = scaffoldMessengerKey.currentState ??
        ScaffoldMessenger.maybeOf(context);
    try {
      await provider.applyTrial();
      messenger?.showSnackBar(
        SnackBar(
          persist: false,
          duration: const Duration(seconds: 5),
          content: const Text('主题已应用'),
          action: SnackBarAction(
            label: '撤销',
            onPressed: () {
              unawaited(provider.restorePreviousAppearance().catchError((_) {
                messenger.showSnackBar(
                  const SnackBar(content: Text('外观未能恢复，请在主题设置中重试。')),
                );
              }));
            },
          ),
        ),
      );
    } catch (_) {
      messenger?.showSnackBar(
        const SnackBar(content: Text('主题应用失败，请重试或结束试用。')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _end(ThemeProvider provider) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await provider.endTrial();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<ThemeProvider?>();
    final trial = provider?.trial;
    if (provider == null || trial == null) return widget.child;

    final tokens = AppThemeTokens.of(context);
    return Column(
      children: [
        Material(
          key: const ValueKey('theme-trial-banner'),
          color: tokens.primaryContainer,
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                children: [
                  Icon(
                    Icons.visibility_outlined,
                    size: 18,
                    color: tokens.onPrimaryContainer,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Semantics(
                      liveRegion: true,
                      child: Text(
                        '试用中 · 《${trial.manifest.name}》',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: tokens.onPrimaryContainer,
                        ),
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: _busy ? null : () => _end(provider),
                    style: TextButton.styleFrom(
                      foregroundColor: tokens.onPrimaryContainer,
                      visualDensity: VisualDensity.compact,
                    ),
                    child: const Text('结束'),
                  ),
                  const SizedBox(width: 4),
                  FilledButton(
                    onPressed: _busy ? null : () => _apply(provider),
                    style: FilledButton.styleFrom(
                      backgroundColor: tokens.primary,
                      foregroundColor: tokens.onPrimary,
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                    ),
                    child: Text(_busy ? '应用中…' : '应用'),
                  ),
                ],
              ),
            ),
          ),
        ),
        Expanded(
          child: MediaQuery.removePadding(
            context: context,
            removeTop: true,
            child: widget.child,
          ),
        ),
      ],
    );
  }
}

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../providers/auth_provider.dart';
import '../../../services/publish_session_scope.dart';
import '../../../widgets/security_session_guard.dart';
import '../data/emoji_submission_repository.dart';
import 'emoji_ui.dart';

/// 页面只能使用打开时的账号会话；切号、重新登录或管理员撤权后不重新认领旧数据。
abstract class EmojiSessionState<T extends StatefulWidget> extends State<T> {
  AuthProvider? auth;
  PublishSessionScope? session;
  EmojiSubmissionRepository? repository;
  CancelToken token = CancelToken();
  bool invalidated = false;
  bool get requireAdmin => false;
  bool get current =>
      mounted &&
      !invalidated &&
      auth != null &&
      session != null &&
      SecuritySessionGuard.owns(auth!, session!, requireAdmin: requireAdmin);
  @override
  void initState() {
    super.initState();
    auth = context.read<AuthProvider?>();
    final user = auth?.user;
    if (auth?.isLoggedIn == true && user != null) {
      session = PublishSessionScope(
          accountId: user.id, accountSessionEpoch: auth!.accountSessionEpoch);
      repository = EmojiSubmissionRepository(auth!.dio);
    }
    auth?.addListener(_sessionChanged);
  }

  void _sessionChanged() {
    if (current || invalidated) return;
    invalidated = true;
    token.cancel('账号或权限已变化');
    onSessionInvalidated();
    if (mounted) setState(() {});
  }

  void onSessionInvalidated() {}
  String failureMessage(Object error) {
    final creatorDenied = error is DioException &&
        error.response?.data is Map &&
        error.response?.data['code'] == 'emoji_creator_required';
    if (error is DioException &&
        (error.response?.statusCode == 401 ||
            requireAdmin &&
                error.response?.statusCode == 403 &&
                !creatorDenied)) {
      invalidated = true;
      token.cancel('账号或权限已失效');
      onSessionInvalidated();
    }
    return emojiSubmissionError(error);
  }

  CancelToken nextRequest() {
    token.cancel('请求已替换');
    return token = CancelToken();
  }

  Widget get permissionState => EmojiStateView(
      icon: Icons.lock_outline,
      title: invalidated
          ? '账号或权限已变化，请返回重新打开'
          : requireAdmin
              ? '需要管理员权限'
              : '请登录后重新打开创作中心');
  @override
  void dispose() {
    token.cancel('页面已关闭');
    auth?.removeListener(_sessionChanged);
    super.dispose();
  }
}

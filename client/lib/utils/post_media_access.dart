import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../models/post.dart';
import '../providers/auth_provider.dart';
import 'governed_post_image_cache.dart';

/// 帖子图片的访问模式。
enum PostMediaAccessMode {
  /// 公开图片：走公开帖子缓存，不带认证头。
  public,

  /// 鉴权私有图片：治理隐藏帖的图片已被服务端降级为 private，必须携带
  /// Bearer JWT 并走账号隔离的私有缓存。
  authorized,
}

/// 帖子图片的访问凭证。
///
/// 用值对象而不是散落地传 `accessMode` + `token` + `accountId` 三个参数，
/// 是为了让「authorized 但没有 token」这种自相矛盾的组合在类型层面无法构造 ——
/// 那种组合的结果是服务器返回 404，表现为「正文能看、图片全裂」，正是本次要修的缺陷。
@immutable
class PostMediaAccess {
  const PostMediaAccess.public()
      : mode = PostMediaAccessMode.public,
        token = null,
        accountId = null;

  const PostMediaAccess.authorized({required String this.token, this.accountId})
      : mode = PostMediaAccessMode.authorized;

  final PostMediaAccessMode mode;

  /// Bearer JWT。只用于请求头，绝不进入缓存 key。
  final String? token;

  /// 当前查看者账号 ID，用于私有缓存作用域。
  final int? accountId;

  bool get isAuthorized => mode == PostMediaAccessMode.authorized;

  /// 鉴权请求头；非鉴权模式或未登录时为空表。
  Map<String, String> get httpHeaders {
    final value = token?.trim() ?? '';
    if (value.isEmpty) return const <String, String>{};
    return <String, String>{'Authorization': 'Bearer $value'};
  }

  /// 私有缓存的账号作用域 key；公开模式返回原 URL，交给公开缓存处理。
  String cacheKeyFor(String url) =>
      isAuthorized ? GovernedPostImageCache.cacheKeyFor(url, accountId: accountId)
                   : url;

  @override
  bool operator ==(Object other) =>
      other is PostMediaAccess &&
      other.mode == mode &&
      other.token == token &&
      other.accountId == accountId;

  @override
  int get hashCode => Object.hash(mode, token, accountId);

  @override
  String toString() => 'PostMediaAccess(${mode.name})';
}

/// 判定一篇帖子的图片应当以什么方式加载。
///
/// 服务端在治理隐藏时会把没有其他公开引用的图片降级为 private，并只对作者与
/// 管理员放行。客户端必须做同构判断：
///
/// ```text
/// 帖子 normal/sold/closed           → public
/// 帖子 moderated_hidden + 作者/管理员 → authorized（Bearer + 私有缓存）
/// 帖子 moderated_hidden + 其他人     → 正常也拿不到（服务端 404），保持 public
/// ```
///
/// 不能为了「图片能显示」把治理帖图片重新当公开资源读 —— 那等于绕过治理。
PostMediaAccess resolvePostMediaAccess(BuildContext context, Post post) {
  if (!post.isModeratedHidden) return const PostMediaAccess.public();

  final auth = context.watch<AuthProvider?>();
  final token = auth?.token?.trim() ?? '';
  if (token.isEmpty) return const PostMediaAccess.public();

  final viewerId = auth?.user?.id;
  final isAuthor = viewerId != null && viewerId == post.authorId;
  final isAdmin = auth?.user?.isAdmin == true;
  if (!isAuthor && !isAdmin) return const PostMediaAccess.public();

  return PostMediaAccess.authorized(token: token, accountId: viewerId);
}

/// 管理端入口：管理员审核待办里查看受治理帖子的图片。
///
/// 管理员不是作者，服务端 `isAuthorizedForPrivateFile` 对 `admin` /
/// `super_admin` 单独放行，因此这里只校验管理员身份，不校验作者。
PostMediaAccess resolveAdminPostMediaAccess(BuildContext context) {
  final auth = context.watch<AuthProvider?>();
  final token = auth?.token?.trim() ?? '';
  if (token.isEmpty || auth?.user?.isAdmin != true) {
    return const PostMediaAccess.public();
  }
  return PostMediaAccess.authorized(token: token, accountId: auth?.user?.id);
}

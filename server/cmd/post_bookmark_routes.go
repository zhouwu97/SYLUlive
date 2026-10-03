package main

import (
	"github.com/gin-gonic/gin"

	"shenliyuan/internal/handlers"
)

// registerPostBookmarkWriteRoutes 注册帖子收藏与取消收藏路由。
//
// 收藏 handler 早已实现，但路由此前从未注册，网页端「收藏」与「我的收藏」
// 一直命中 404。写入路由挂在 postsAuth 组（登录 + 已接受社区规则），
// 与点赞路由同组同中间件。注册位置由 post_bookmark_routes_test.go 锁定。
func registerPostBookmarkWriteRoutes(postsAuth *gin.RouterGroup, postHandler *handlers.PostHandler) {
	postsAuth.PUT("/:id/bookmark", postHandler.PutBookmark)
	postsAuth.DELETE("/:id/bookmark", postHandler.DeleteBookmark)
}

// registerPostBookmarkListRoute 注册当前用户收藏列表路由。
//
// 必须在 userOptional 的 /:id 静态冲突窗口之前注册：本 gin 版本要求
// 同层静态路径先于参数路径注册（见 announcement_routes.go 同类注释）。
func registerPostBookmarkListRoute(user *gin.RouterGroup, postHandler *handlers.PostHandler) {
	user.GET("/bookmarks", postHandler.ListBookmarks)
}

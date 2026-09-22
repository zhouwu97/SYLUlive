package middleware

import (
	"context"
	"log"
	"net/http"
	"strings"
	"sync"

	"github.com/gin-gonic/gin"
)

var securityBlockReadinessWarning sync.Once

type securityBlockHealthReporter interface {
	SetSecurityBlockDegraded(bool)
}

// SecurityBlockChecker 由安全中心服务实现；查询失败时中间件按既有策略 fail-open。
type SecurityBlockChecker interface {
	IsBlocked(clientIP, route string) (bool, error)
}

// contextAwareSecurityBlockChecker 是可选能力：实现它的 checker 会收到请求 context，
// 使查询可随 HTTP 请求取消。未实现时回退到 IsBlocked，保持既有实现与测试可用。
type contextAwareSecurityBlockChecker interface {
	IsBlockedContext(ctx context.Context, clientIP, route string) (bool, error)
}

// SecurityBlockMiddleware 只在高风险 API 路径查询临时来源封禁。
//
// 注意：这是**路径前缀**策略，不是方法策略。`/api/posts`、`/api/search` 等前缀
// 同样覆盖其上的普通 GET 读请求，因此“普通静态/读请求不增加数据库查询”只对
// 未命中前缀的请求成立，不能据此认为读请求一定不查库。
// 本轮只做策略收敛（消除两份不一致的清单），不静默扩大或缩小覆盖面。
func SecurityBlockMiddleware(checker SecurityBlockChecker) gin.HandlerFunc {
	return func(c *gin.Context) {
		if !SensitiveSecurityRoute(c.Request.URL.Path) {
			c.Next()
			return
		}
		// 优先传递请求 context：客户端中断时封禁查询随之取消，不占用连接空转。
		var blocked bool
		var err error
		if aware, ok := checker.(contextAwareSecurityBlockChecker); ok {
			blocked, err = aware.IsBlockedContext(c.Request.Context(), c.ClientIP(), c.Request.URL.Path)
		} else {
			blocked, err = checker.IsBlocked(c.ClientIP(), c.Request.URL.Path)
		}
		if err != nil {
			if reporter, ok := checker.(securityBlockHealthReporter); ok {
				reporter.SetSecurityBlockDegraded(true)
			}
			securityBlockReadinessWarning.Do(func() {
				log.Printf("ERROR security block unavailable, fail-open: %v", err)
			})
			// 附加封禁层查询失败时 fail-open；健康检查会同步显示 degraded。
			// fail-open 只表示“该附加层这次给不出判断”，绝不代表可以跳过账号鉴权、
			// 业务权限、内容额度或其它安全门禁——后续中间件与 handler 照常执行。
			c.Next()
			return
		}
		if reporter, ok := checker.(securityBlockHealthReporter); ok {
			reporter.SetSecurityBlockDegraded(false)
		}
		if blocked {
			c.Header("Retry-After", "60")
			c.JSON(http.StatusTooManyRequests, gin.H{"error": "当前来源暂时受限，请稍后再试", "code": "security_source_blocked"})
			c.Abort()
			return
		}
		c.Next()
	}
}

// SecurityRouteGroupID 是一组同用途账号/内容接口的稳定标识。
// 管理员选择封禁范围、界面展示实际路径、中间件判断是否查封禁表，全部引用这些 ID，
// 不再各自抄一份路径数组——A12 的成因就是两份数组各自漂移。
type SecurityRouteGroupID string

const (
	// SecurityGroupLogin 覆盖凭据换取令牌与注册入口。
	SecurityGroupLogin SecurityRouteGroupID = "login"
	// SecurityGroupVerification 覆盖验证码收发入口。
	SecurityGroupVerification SecurityRouteGroupID = "verification"
	// SecurityGroupCredentialChange 覆盖改密与邮箱换绑。
	SecurityGroupCredentialChange SecurityRouteGroupID = "credential_change"
	// SecurityGroupSessionRefresh 覆盖会话令牌刷新。
	SecurityGroupSessionRefresh SecurityRouteGroupID = "session_refresh"
	// SecurityGroupContentWrite 覆盖用户可批量提交的写入与检索入口。
	SecurityGroupContentWrite SecurityRouteGroupID = "content_write"
)

// SecurityRouteGroup 登记一段路由前缀的用途与归属。
//
// Prefixes 只允许完整路由段前缀（如 /api/user/email 同时覆盖 /api/user/email/code），
// 匹配规则见 securityRoutePrefix。
type SecurityRouteGroup struct {
	ID       SecurityRouteGroupID `json:"id"`
	Purpose  string               `json:"purpose"`
	Prefixes []string             `json:"prefixes"`
}

// securityRouteGroups 是来源封禁的唯一路由清单。
//
// 清单依据 cmd/main.go 实际注册的路由（均为 /api 前缀）：
//   - /api/login、/api/login_edu：普通登录与教务登录，撞库主战场
//   - /api/register*：批量注册
//   - /api/forgot_password、/api/password/*：找回与重置链路
//   - /api/send_code、/api/verify_code：验证码轰炸（成本与骚扰）
//   - /api/change_password、/api/user/email*：改密与邮箱换绑，账号接管的落地一步
//   - /api/refresh、/api/auth/refresh：会话令牌刷新，被盗令牌续命与复用检测的位置
//   - /api/search、/api/posts、/api/messages、/api/feedback：爬取与批量写入入口
//   - /api/logout 未纳入：需要有效令牌，不具备撞库/批量注册价值，纳入会扩大封禁面。
//
// 决策依据来自路由注册与审计证据，不凭字符串猜测新增兼容别名。
var securityRouteGroups = []SecurityRouteGroup{
	{
		ID:       SecurityGroupLogin,
		Purpose:  "登录、教务登录与注册入口（撞库与批量注册）",
		Prefixes: []string{"/api/login", "/api/login_edu", "/api/register", "/api/forgot_password", "/api/password"},
	},
	{
		ID:       SecurityGroupVerification,
		Purpose:  "验证码收发（骚扰与邮件成本）",
		Prefixes: []string{"/api/send_code", "/api/verify_code"},
	},
	{
		ID:       SecurityGroupCredentialChange,
		Purpose:  "改密与邮箱换绑（账号接管的落地步骤）",
		Prefixes: []string{"/api/change_password", "/api/user/email"},
	},
	{
		ID:       SecurityGroupSessionRefresh,
		Purpose:  "会话令牌刷新（被盗续命与令牌复用）",
		Prefixes: []string{"/api/refresh", "/api/auth/refresh"},
	},
	{
		ID:       SecurityGroupContentWrite,
		Purpose:  "内容写入与检索（批量提交、爬取与放大攻击）",
		Prefixes: []string{"/api/search", "/api/posts", "/api/messages", "/api/feedback"},
	},
}

// SecurityAccountRouteGroups 是「账号安全」范围包含的分组：凭据入口、验证码、
// 改密/换绑、会话刷新。内容写入与检索刻意排除——把它们整段封掉会误伤大量正常读写，
// 尤其是校园共享出口下的普通浏览。
var SecurityAccountRouteGroups = []SecurityRouteGroupID{
	SecurityGroupLogin,
	SecurityGroupVerification,
	SecurityGroupCredentialChange,
	SecurityGroupSessionRefresh,
}

// SecurityRouteGroupByID 按 ID 取分组，找不到返回 false，调用方不得回退成「全部」。
func SecurityRouteGroupByID(id SecurityRouteGroupID) (SecurityRouteGroup, bool) {
	for _, group := range securityRouteGroups {
		if group.ID == id {
			return group, true
		}
	}
	return SecurityRouteGroup{}, false
}

// SecurityRouteGroups 返回若干分组的登记信息，供界面展示「这个范围到底是哪几条路由」。
// 传入未知 ID 时返回 ok=false：范围清单不能静默丢掉一段路由。
func SecurityRouteGroups(ids []SecurityRouteGroupID) ([]SecurityRouteGroup, bool) {
	out := make([]SecurityRouteGroup, 0, len(ids))
	for _, id := range ids {
		group, ok := SecurityRouteGroupByID(id)
		if !ok {
			return nil, false
		}
		out = append(out, group)
	}
	return out, true
}

// SecurityRoutePrefixes 返回若干分组的完整前缀集合（去重、按登记顺序）。
// 传入未知 ID 时返回 ok=false：范围清单不能静默丢掉一段路由。
func SecurityRoutePrefixes(ids []SecurityRouteGroupID) ([]string, bool) {
	groups, ok := SecurityRouteGroups(ids)
	if !ok {
		return nil, false
	}
	seen := map[string]struct{}{}
	out := make([]string, 0, 16)
	for _, group := range groups {
		for _, prefix := range group.Prefixes {
			if _, duplicated := seen[prefix]; duplicated {
				continue
			}
			seen[prefix] = struct{}{}
			out = append(out, prefix)
		}
	}
	return out, true
}

// SensitiveSecurityRoute 是临时来源封禁的**唯一**路由策略，直接由上表推导。
func SensitiveSecurityRoute(path string) bool {
	for _, group := range securityRouteGroups {
		for _, prefix := range group.Prefixes {
			if securityRoutePrefix(path, prefix) {
				return true
			}
		}
	}
	return false
}

// securityRoutePrefix 只匹配完整路由段，避免把 /api/postsomething 误当成 /api/posts。
func securityRoutePrefix(path, prefix string) bool {
	return path == prefix || strings.HasPrefix(path, prefix+"/")
}

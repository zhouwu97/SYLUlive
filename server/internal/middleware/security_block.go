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

// SensitiveSecurityRoute 是临时来源封禁的**唯一**路由策略。
//
// 这里曾经存在两份内容不一致的清单（middleware 私有版与 services 导出版），
// 后者多出 /api/forgot_password、/api/refresh、/api/auth/refresh、/api/change_password、
// /api/user/email，中间件实际使用的是缺项的那一份。现在以本函数为唯一来源，
// services.IsSensitiveSecurityRoute 直接委托到这里，避免再次分叉。
//
// 清单依据 cmd/main.go 实际注册的路由（均为 /api 前缀）：
//   - /api/login、/api/refresh、/api/auth/refresh：凭据换取令牌，撞库主战场
//   - /api/register、/api/register/email、/api/register/email/code：批量注册
//   - /api/forgot_password、/api/password/email/code、/api/password/email/reset、
//     /api/password/edu/reset、/api/change_password：账号接管与改密链路
//   - /api/send_code、/api/verify_code：验证码轰炸（成本与骚扰）
//   - /api/user/email、/api/user/email/code：邮箱换绑
//   - /api/search：检索型读取，历史上是爬取与放大攻击入口
//   - /api/posts、/api/messages、/api/feedback：用户可批量提交的写入入口
//   - /api/logout 未纳入：需要有效令牌，不具备撞库/批量注册价值，纳入会扩大封禁面。
//
// 决策依据来自路由注册与审计证据，不凭字符串猜测新增兼容别名。
func SensitiveSecurityRoute(path string) bool {
	return securityRoutePrefix(path, "/api/login") ||
		securityRoutePrefix(path, "/api/login_edu") ||
		securityRoutePrefix(path, "/api/password") ||
		securityRoutePrefix(path, "/api/register") ||
		securityRoutePrefix(path, "/api/forgot_password") ||
		securityRoutePrefix(path, "/api/refresh") ||
		securityRoutePrefix(path, "/api/auth/refresh") ||
		securityRoutePrefix(path, "/api/change_password") ||
		securityRoutePrefix(path, "/api/user/email") ||
		securityRoutePrefix(path, "/api/send_code") ||
		securityRoutePrefix(path, "/api/verify_code") ||
		securityRoutePrefix(path, "/api/search") ||
		securityRoutePrefix(path, "/api/posts") ||
		securityRoutePrefix(path, "/api/messages") ||
		securityRoutePrefix(path, "/api/feedback")
}

// securityRoutePrefix 只匹配完整路由段，避免把 /api/postsomething 误当成 /api/posts。
func securityRoutePrefix(path, prefix string) bool {
	return path == prefix || strings.HasPrefix(path, prefix+"/")
}

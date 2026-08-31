package handlers

import (
	"net/http"

	"github.com/gin-gonic/gin"
)

// 退役响应只携带稳定错误码和迁移提示，不读取、绑定或记录请求体。
// 这些 Handler 由发布开关显式装配，便于 C2/C3/D 分阶段验收。
const (
	LegacyEduRouteRetiredCode         = "LEGACY_EDU_ROUTE_RETIRED"
	SchoolAcademicRouteRetiredCode    = "SCHOOL_ACADEMIC_ROUTE_RETIRED"
	SchoolDeviceCapabilityRetiredCode = "SCHOOL_DEVICE_CAPABILITY_RETIRED"
)

// RegisterRetiredSchoolAuthorityRoutes 集中装配 Release D 的退役入口。
//
// 这些路由必须直接注册到顶层 Engine，不能复用旧路由组的认证或 Body
// 中间件。全局 TLS、版本门禁和请求追踪仍可先执行，但旧认证、绑定、凭据
// 校验和业务 Handler 不会进入调用链。
func RegisterRetiredSchoolAuthorityRoutes(router gin.IRouter) {
	for _, route := range []struct {
		path    string
		handler gin.HandlerFunc
	}{
		{path: "/api/login_edu", handler: RetiredLegacyEduRoute},
		{path: "/api/register_with_edu", handler: RetiredLegacyEduRoute},
		{path: "/api/forgot_password", handler: RetiredLegacyEduRoute},
		{path: "/api/password/edu/reset", handler: RetiredLegacyEduRoute},
		{path: "/api/personal-snapshots/erke", handler: RetiredSchoolAcademicRoute},
	} {
		router.Any(route.path, route.handler)
		router.Any(route.path+"/", route.handler)
	}
	router.Any("/api/edu", RetiredSchoolAcademicRoute)
	router.Any("/api/edu/*path", RetiredSchoolAcademicRoute)
}

// RetiredLegacyEduRoute 退役登录、注册和教务密码找回入口。
func RetiredLegacyEduRoute(c *gin.Context) {
	writeRetiredRoute(c, LegacyEduRouteRetiredCode, "旧教务账号入口已退役，请使用邮箱账号")
}

// RetiredSchoolAcademicRoute 退役 Go 教务与个人学校快照路由。
func RetiredSchoolAcademicRoute(c *gin.Context) {
	writeRetiredRoute(c, SchoolAcademicRouteRetiredCode, "服务端学校个人数据接口已退役，请使用客户端本地能力")
}

// RetiredSchoolDeviceCapability 退役设备学校个人数据任务接口。
func RetiredSchoolDeviceCapability(c *gin.Context) {
	writeRetiredRoute(c, SchoolDeviceCapabilityRetiredCode, "学校设备能力已退役")
}

func writeRetiredRoute(c *gin.Context, code, message string) {
	// 不调用 c.ShouldBind*、c.GetRawData 或任何会触碰 Body 的 API。
	c.Header("Cache-Control", "no-store")
	c.Header("Sunset", "true")
	c.JSON(http.StatusGone, gin.H{
		"code":    code,
		"message": message,
	})
	c.Abort()
}

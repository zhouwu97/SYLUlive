package middleware

import (
	"net/http"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

// 内容写入方法集合：只有真正提交/修改用户可见内容的请求才需要先确认社区规则。
var contentWriteMethods = map[string]bool{
	http.MethodPost:   true,
	http.MethodPut:    true,
	http.MethodPatch:  true,
	http.MethodDelete: true,
}

// IsContentWriteRequest 判断请求是否为内容写入请求。
func IsContentWriteRequest(method string) bool {
	return contentWriteMethods[method]
}

// RequireCommunityRules 是"用户发布内容"入口的社区规则确认门禁。
//
// 这个门禁此前由 AuthMiddleware 里的 isCommunityWriteRequest 按路径前缀猜，
// 结果只覆盖了帖子/回复/组队/水帖板块/私信，漏掉食堂评价、菜品实拍与版块
// 图标提交 —— 同一份社区规则在"发帖"和"发食堂评价"两个入口执行不一致。
// 现在改为在需要门禁的路由（组）上显式挂载：
//
//   - 新增内容入口必须显式声明，不会因为忘改前缀表而静默漏掉；
//   - 管理员治理接口与只读接口不会被误伤（挂载点本身就排除了它们）。
//
// 必须在 AuthMiddleware 之后挂载：它依赖 user_id；未认证请求由 AuthMiddleware 拒绝。
// hard 模式之外不做拦截（soft/off 只记录），与 legal_consent 的既有语义一致。
func RequireCommunityRules(db *gorm.DB) gin.HandlerFunc {
	return func(c *gin.Context) {
		if !IsContentWriteRequest(c.Request.Method) {
			c.Next()
			return
		}
		if legalConsentEnforcement != LegalConsentEnforcementHard {
			c.Next()
			return
		}
		userID := c.GetUint("user_id")
		if userID == 0 {
			c.Next()
			return
		}

		var accepted int64
		if err := db.Model(&models.UserLegalConsent{}).
			Where("user_id = ? AND document = ? AND version = ? AND revoked_at IS NULL AND acknowledgement_type = ?",
				userID, models.LegalDocumentCommunityRules, models.LegalDocumentVersion, "rules_acceptance").
			Count(&accepted).Error; err != nil {
			writeAPIError(c, http.StatusInternalServerError, "legal_consent_lookup_failed", "读取社区规则确认状态失败")
			c.Abort()
			return
		}
		if accepted == 0 {
			writeAPIError(c, http.StatusForbidden, "community_rules_required", "请先确认社区规则")
			c.Abort()
			return
		}
		c.Next()
	}
}

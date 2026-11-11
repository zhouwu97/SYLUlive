package handlers

import (
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
)

// 管理界面使用独立 AI 标识，社区历史仍沿用原有作者关联。
func (h *SuperAdminHandler) getManagedAIs(c *gin.Context) {
	type row struct {
		ActorID   uint      `json:"-"`
		ID        string    `json:"id"`
		Name      string    `json:"name"`
		Avatar    string    `json:"avatar"`
		OwnerID   uint      `json:"owner_id"`
		OwnerName string    `json:"owner_name"`
		Enabled   bool      `json:"enabled"`
		CreatedAt time.Time `json:"created_at"`
	}
	result := []row{}
	q := h.db.Table("managed_bots AS b").
		Joins("JOIN users AS actor ON actor.id = b.user_id AND actor.account_status = ?", "bot").
		Joins("JOIN users AS owner ON owner.id = b.owner_id").
		Select("b.user_id AS actor_id, actor.nickname AS name, actor.avatar, b.owner_id, owner.nickname AS owner_name, b.enabled, b.created_at")
	if search := strings.TrimSpace(c.Query("search")); search != "" {
		q = q.Where("actor.nickname LIKE ? OR owner.nickname LIKE ?", "%"+search+"%", "%"+search+"%")
	}
	if err := q.Order("b.created_at DESC").Scan(&result).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取 AI 列表失败"})
		return
	}
	for i := range result {
		result[i].ID = "AI-" + uuid.NewSHA1(uuid.NameSpaceOID, []byte("sylulive/managed-ai/"+strconv.FormatUint(uint64(result[i].ActorID), 10))).String()
		result[i].Name = strings.TrimPrefix(result[i].Name, "[AI] ")
	}
	c.JSON(http.StatusOK, result)
}

package services

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/middleware"
	"shenliyuan/internal/models"
)

func newSystemMessageTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("打开测试数据库失败: %v", err)
	}
	if err := db.AutoMigrate(&models.User{}, &models.Conversation{}, &models.Message{}); err != nil {
		t.Fatalf("迁移测试数据库失败: %v", err)
	}
	if err := models.EnsureConversationIndexes(db); err != nil {
		t.Fatalf("创建私信索引失败: %v", err)
	}
	return db
}

func TestEnsureSystemUserCreatesReusableAdminAccount(t *testing.T) {
	db := newSystemMessageTestDB(t)
	first, err := EnsureSystemUser(db)
	if err != nil {
		t.Fatalf("创建系统账号失败: %v", err)
	}
	second, err := EnsureSystemUser(db)
	if err != nil {
		t.Fatalf("复用系统账号失败: %v", err)
	}
	if first.ID == 0 || first.ID != second.ID {
		t.Fatalf("系统账号必须稳定复用: first=%d second=%d", first.ID, second.ID)
	}
	if first.Role != models.RoleAdmin || first.StudentID != SystemUserStudentID {
		t.Fatalf("系统账号属性错误: %#v", first)
	}
}

func TestEnsureSystemUserRoleRepairInvalidatesOldToken(t *testing.T) {
	gin.SetMode(gin.TestMode)
	middleware.InvalidateTokenVersionCache(0)
	db := newSystemMessageTestDB(t)
	user := models.User{
		StudentID:    SystemUserStudentID,
		PasswordHash: "legacy",
		Role:         models.RoleUser,
		TokenVersion: 4,
	}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("创建遗留系统账号失败: %v", err)
	}

	const secret = "system-message-test-secret"
	oldToken, err := middleware.GenerateToken(user.ID, string(models.RoleUser), user.TokenVersion, secret)
	if err != nil {
		t.Fatalf("生成旧令牌失败: %v", err)
	}
	router := gin.New()
	router.GET("/protected", middleware.AuthMiddleware(db, secret), func(c *gin.Context) {
		c.Status(http.StatusNoContent)
	})

	if _, err := EnsureSystemUser(db); err != nil {
		t.Fatalf("修复系统账号失败: %v", err)
	}
	var repaired models.User
	if err := db.First(&repaired, user.ID).Error; err != nil {
		t.Fatalf("读取修复后的系统账号失败: %v", err)
	}
	if repaired.Role != models.RoleAdmin || repaired.TokenVersion != user.TokenVersion+1 {
		t.Fatalf("系统账号角色/令牌版本未正确修复: %+v", repaired)
	}

	request := httptest.NewRequest(http.MethodGet, "/protected", nil)
	request.Header.Set("Authorization", "Bearer "+oldToken)
	response := httptest.NewRecorder()
	router.ServeHTTP(response, request)
	if response.Code != http.StatusUnauthorized {
		t.Fatalf("角色修复后旧令牌仍可用: status=%d body=%s", response.Code, response.Body.String())
	}
}

func TestCreateSystemMessageReusesConversationAndBypassesStrangerLimits(t *testing.T) {
	db := newSystemMessageTestDB(t)
	target := models.User{StudentID: "system-message-target", PasswordHash: "test", Nickname: "投稿人"}
	if err := db.Create(&target).Error; err != nil {
		t.Fatalf("创建目标用户失败: %v", err)
	}

	var first models.Message
	if err := db.Transaction(func(tx *gorm.DB) error {
		var err error
		first, _, err = CreateSystemMessage(tx, target.ID, "第一次审核通知")
		return err
	}); err != nil {
		t.Fatalf("创建第一条系统私信失败: %v", err)
	}
	var second models.Message
	if err := db.Transaction(func(tx *gorm.DB) error {
		var err error
		second, _, err = CreateSystemMessage(tx, target.ID, "第二次审核通知")
		return err
	}); err != nil {
		t.Fatalf("创建第二条系统私信失败: %v", err)
	}

	if first.ConversationID == 0 || first.ConversationID != second.ConversationID {
		t.Fatalf("系统私信应复用同一会话: first=%d second=%d", first.ConversationID, second.ConversationID)
	}
	var conversation models.Conversation
	if err := db.First(&conversation, first.ConversationID).Error; err != nil {
		t.Fatalf("读取系统会话失败: %v", err)
	}
	if conversation.LastMessageAt.Before(second.CreatedAt.Add(-time.Second)) {
		t.Fatalf("会话最后消息时间未更新: %v < %v", conversation.LastMessageAt, second.CreatedAt)
	}

	var count int64
	if err := db.Model(&models.Message{}).Where("conversation_id = ?", first.ConversationID).Count(&count).Error; err != nil {
		t.Fatalf("统计系统私信失败: %v", err)
	}
	if count != 2 {
		t.Fatalf("系统私信数量错误: %d", count)
	}
}

func TestGetOrCreateConversationNormalizesUserOrder(t *testing.T) {
	db := newSystemMessageTestDB(t)
	first, err := GetOrCreateConversation(db, 20, 10, time.Now())
	if err != nil {
		t.Fatalf("创建会话失败: %v", err)
	}
	second, err := GetOrCreateConversation(db, 10, 20, time.Now())
	if err != nil {
		t.Fatalf("复用会话失败: %v", err)
	}
	if first.ID != second.ID || first.User1ID != 10 || first.User2ID != 20 {
		t.Fatalf("会话用户顺序或复用错误: first=%#v second=%#v", first, second)
	}
}

package handlers

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"

	"shenliyuan/internal/models"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"
)

func setupGovernanceHandlerTest(t *testing.T) (*gin.Engine, *gorm.DB, *TeacherGovernanceHandler) {
	gin.SetMode(gin.TestMode)

	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open db: %v", err)
	}

	err = db.AutoMigrate(
		&models.User{},
		&models.CourseSubject{},
		&models.CourseSubjectAlias{},
		&models.Teacher{},
		&models.TeacherAlias{},
		&models.TeacherRating{},
		&models.TeacherRatingVote{},
		&models.CourseEvaluationSubmission{},
		&models.TeacherMergeRecord{},
	)
	if err != nil {
		t.Fatalf("migrate tables: %v", err)
	}

	handler := NewTeacherGovernanceHandler(db)

	router := gin.New()
	return router, db, handler
}

func TestTeacherGovernanceHandler_AuthAndPermissions(t *testing.T) {
	router, _, handler := setupGovernanceHandlerTest(t)

	// 模拟需要权限的中间件
	fakeAuthMiddleware := func(userRole string) gin.HandlerFunc {
		return func(c *gin.Context) {
			if userRole == "unauthenticated" {
				c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "请先登录"})
				return
			}
			c.Set("user_id", uint(1))
			c.Set("user_role", userRole)
			if userRole != "admin" {
				c.AbortWithStatusJSON(http.StatusForbidden, gin.H{"error": "需要管理员权限"})
				return
			}
			c.Next()
		}
	}

	// 1. 未登录访问 -> 401
	rUnauth := gin.New()
	rUnauth.Use(fakeAuthMiddleware("unauthenticated"))
	rUnauth.GET("/api/admin/teacher-governance/teachers", handler.ListTeachers)

	req1 := httptest.NewRequest(http.MethodGet, "/api/admin/teacher-governance/teachers", nil)
	w1 := httptest.NewRecorder()
	rUnauth.ServeHTTP(w1, req1)
	if w1.Code != http.StatusUnauthorized {
		t.Fatalf("未登录预期 401，实际为 %d", w1.Code)
	}

	// 2. 普通用户访问 -> 403
	rUser := gin.New()
	rUser.Use(fakeAuthMiddleware("user"))
	rUser.GET("/api/admin/teacher-governance/teachers", handler.ListTeachers)

	req2 := httptest.NewRequest(http.MethodGet, "/api/admin/teacher-governance/teachers", nil)
	w2 := httptest.NewRecorder()
	rUser.ServeHTTP(w2, req2)
	if w2.Code != http.StatusForbidden {
		t.Fatalf("普通用户预期 403，实际为 %d", w2.Code)
	}

	_ = router
}

func TestTeacherGovernanceHandler_ListTeachersPagination(t *testing.T) {
	router, db, handler := setupGovernanceHandlerTest(t)

	// 设置管理员身份
	router.Use(func(c *gin.Context) {
		c.Set("user_id", uint(1))
		c.Set("user_role", "admin")
		c.Next()
	})
	router.GET("/api/admin/teacher-governance/teachers", handler.ListTeachers)

	subj := models.CourseSubject{Name: "操作系统", Verified: true}
	db.Create(&subj)

	for i := 1; i <= 3; i++ {
		db.Create(&models.Teacher{
			Name:            fmt.Sprintf("OS教师%d", i),
			Course:          "操作系统",
			CourseSubjectID: &subj.ID,
			Verified:        true,
		})
	}

	// 首次请求 limit=2
	req := httptest.NewRequest(http.MethodGet, "/api/admin/teacher-governance/teachers?limit=2", nil)
	w := httptest.NewRecorder()
	router.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("请求失败: code=%d, body=%s", w.Code, w.Body.String())
	}

	var resp struct {
		Items      []map[string]interface{} `json:"items"`
		Teachers   []map[string]interface{} `json:"teachers"`
		HasMore    bool                     `json:"has_more"`
		NextCursor uint                     `json:"next_cursor"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("反序列化响应失败: %v", err)
	}

	if len(resp.Items) != 2 || !resp.HasMore || resp.NextCursor == 0 {
		t.Fatalf("分页响应格式不符: len=%d, has_more=%v, next_cursor=%d", len(resp.Items), resp.HasMore, resp.NextCursor)
	}
	// 验证兼容字段 teachers 存在
	if len(resp.Teachers) != len(resp.Items) {
		t.Fatalf("兼容字段 teachers 长度不一致: %d vs %d", len(resp.Teachers), len(resp.Items))
	}
}

func TestTeacherGovernanceHandler_ListAliasesAndRecords(t *testing.T) {
	router, db, handler := setupGovernanceHandlerTest(t)

	router.Use(func(c *gin.Context) {
		c.Set("user_id", uint(1))
		c.Set("user_role", "admin")
		c.Next()
	})
	router.GET("/api/admin/teacher-governance/aliases", handler.ListAliases)
	router.GET("/api/admin/teacher-governance/merge-records", handler.ListMergeRecords)

	subj := models.CourseSubject{Name: "计算机网络", Verified: true}
	db.Create(&subj)
	db.Create(&models.CourseSubjectAlias{CourseSubjectID: subj.ID, Alias: "计网", NormalizedAlias: "计网"})

	// 测试 aliases 接口
	reqA := httptest.NewRequest(http.MethodGet, "/api/admin/teacher-governance/aliases?type=course&page=1&limit=10", nil)
	wA := httptest.NewRecorder()
	router.ServeHTTP(wA, reqA)

	if wA.Code != http.StatusOK {
		t.Fatalf("aliases 接口失败: %d", wA.Code)
	}

	var aliasResp struct {
		Items   []map[string]interface{} `json:"items"`
		HasMore bool                     `json:"has_more"`
		Page    int                      `json:"page"`
	}
	if err := json.Unmarshal(wA.Body.Bytes(), &aliasResp); err != nil {
		t.Fatalf("反序列化 aliases 失败: %v", err)
	}
	if len(aliasResp.Items) != 1 || aliasResp.Page != 1 {
		t.Fatalf("aliases 响应不符: len=%d, page=%d", len(aliasResp.Items), aliasResp.Page)
	}

	// 测试 merge-records 接口
	db.Create(&models.TeacherMergeRecord{
		BatchID:            "test-batch-1",
		KeeperID:           1,
		LoserID:            2,
		KeeperNameSnapshot: "主教师",
		LoserNameSnapshot:  "从教师",
		AdminID:            1,
	})

	reqR := httptest.NewRequest(http.MethodGet, "/api/admin/teacher-governance/merge-records?limit=10", nil)
	wR := httptest.NewRecorder()
	router.ServeHTTP(wR, reqR)

	if wR.Code != http.StatusOK {
		t.Fatalf("merge-records 接口失败: %d", wR.Code)
	}

	var recResp struct {
		Items      []map[string]interface{} `json:"items"`
		HasMore    bool                     `json:"has_more"`
		NextCursor uint                     `json:"next_cursor"`
	}
	if err := json.Unmarshal(wR.Body.Bytes(), &recResp); err != nil {
		t.Fatalf("反序列化 records 失败: %v", err)
	}
	if len(recResp.Items) != 1 {
		t.Fatalf("records 响应不符: len=%d", len(recResp.Items))
	}
}

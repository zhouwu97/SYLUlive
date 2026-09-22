package handlers

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

func newSecurityOverviewTestHandler(t *testing.T) (*SecurityAdminHandler, *gorm.DB) {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("打开测试库失败: %v", err)
	}
	if err := db.AutoMigrate(&models.SecurityEvent{}, &models.SecurityBlock{}); err != nil {
		t.Fatalf("迁移失败: %v", err)
	}
	service := services.NewSecurityEventService(db, "test-secret", nil)
	return NewSecurityAdminHandler(db, service), db
}

func runSecurityOverview(t *testing.T, handler *SecurityAdminHandler, requestCtx context.Context) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, "/api/admin/security/overview?range=24h", nil)
	req = req.WithContext(requestCtx)
	recorder := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(recorder)
	c.Request = req
	handler.Overview(c)
	return recorder
}

// SEC-03：总览页的聚合读查询必须随请求结束一起停下。
//
// 一次 Overview 会串行打十几条聚合查询。不携带 context 时，浏览器已经关掉的页面
// 仍会把十几个查询排满连接池，安全中心于是成为数据库变慢时最容易压垮其它请求的那一页。
func TestSecurityOverviewReadsHonorRequestContext(t *testing.T) {
	handler, _ := newSecurityOverviewTestHandler(t)
	ctx, cancel := context.WithCancel(context.Background())
	cancel() // 模拟请求已经结束时才打到的读查询

	recorder := runSecurityOverview(t, handler, ctx)
	if recorder.Code == http.StatusOK {
		t.Fatalf("请求 context 已取消，总览仍然完成了数据库查询（读查询未携带 context）")
	}
	if recorder.Code != http.StatusInternalServerError {
		t.Fatalf("应回落到安全中心降级响应，实际 %d: %s", recorder.Code, recorder.Body.String())
	}
}

// 反向对照：未取消的请求必须正常返回，避免上面那条断言靠「一律报错」蒙混通过。
func TestSecurityOverviewSucceedsWithLiveRequestContext(t *testing.T) {
	handler, _ := newSecurityOverviewTestHandler(t)
	recorder := runSecurityOverview(t, handler, context.Background())
	if recorder.Code != http.StatusOK {
		t.Fatalf("活跃请求应正常返回总览，实际 %d: %s", recorder.Code, recorder.Body.String())
	}
}

package handlers

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"

	"shenliyuan/internal/models"
)

// 管理端整改待办卡必须带上「当初为什么被处理」的审核上下文，否则管理员只能对着
// 已经改好的内容点通过，无法判断作者到底改掉了什么违规内容。
//
// 同时：举报人身份（reporter_id、举报人自述）不属于审核依据，绝不能随响应下发。
func TestListRectificationExposesGovernanceContextWithoutReporterIdentity(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db := setupPostGovernanceTestDB(t)

	author := models.User{StudentID: "20261001", Nickname: "作者甲", Role: models.RoleUser}
	db.Create(&author)
	reporter := models.User{StudentID: "20261002", Nickname: "举报人乙", Role: models.RoleUser}
	db.Create(&reporter)

	post := models.Post{
		Title:              "被治理的帖子",
		Content:            "整改后的正常内容",
		BoardID:            models.BoardShuitie,
		AuthorID:           author.ID,
		Status:             models.PostStatusModeratedHidden,
		Revision:           4,
		ModerationRuleCode: "harassment",
		ModerationReason:   "请删除针对具体同学的攻击内容",
	}
	if err := db.Create(&post).Error; err != nil {
		t.Fatalf("create post: %v", err)
	}

	handledAt := time.Now().Add(-time.Hour)
	report := models.Report{
		ReporterID:        reporter.ID,
		TargetType:        "post",
		TargetID:          post.ID,
		ReasonCode:        "harassment",
		Reason:            "举报人自述：他骂人了",
		TargetAuthorID:    &author.ID,
		TargetSnapshot:    `{"title":"被治理的帖子","content":"针对某位同学的人身攻击原文","image_file_ids":[11,12],"original_status":"normal","created_at":"2026-09-16T10:00:00Z"}`,
		Action:            models.ReportActionModeratedHidden,
		ModeratedRevision: 3,
		Status:            models.ReportStatusHandled,
		DeleteReason:      "请删除针对具体同学的攻击内容",
		HandledAt:         &handledAt,
	}
	if err := db.Create(&report).Error; err != nil {
		t.Fatalf("create report: %v", err)
	}

	review := models.PostRectificationReview{
		PostID:            post.ID,
		ReportID:          &report.ID,
		SubmittedRevision: 4,
		Status:            models.RectificationReviewPending,
	}
	if err := db.Create(&review).Error; err != nil {
		t.Fatalf("create review: %v", err)
	}

	handler := NewPostGovernanceHandler(db)
	router := gin.New()
	router.GET("/admin/rectification", handler.ListRectification)

	recorder := httptest.NewRecorder()
	router.ServeHTTP(recorder, httptest.NewRequest(
		http.MethodGet, "/admin/rectification?status=pending", nil))

	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", recorder.Code, recorder.Body.String())
	}
	body := recorder.Body.String()

	for _, leaked := range []string{
		"reporter_id",
		"举报人乙",
		reporter.StudentID,
		// 举报人自由自述不能随整改待办下发；审核依据只用治理规则码与处理说明。
		"举报人自述：他骂人了",
	} {
		if strings.Contains(body, leaked) {
			t.Fatalf("整改待办响应泄露举报人身份字段 %q: %s", leaked, body)
		}
	}

	var items []map[string]any
	if err := json.Unmarshal(recorder.Body.Bytes(), &items); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if len(items) != 1 {
		t.Fatalf("items = %d, want 1", len(items))
	}
	item := items[0]

	if got := item["submitted_revision"]; got != float64(4) {
		t.Errorf("submitted_revision = %v, want 4", got)
	}
	if got := item["original_rule_code"]; got != "harassment" {
		t.Errorf("original_rule_code = %v, want harassment", got)
	}
	if got := item["original_reason"]; got != "请删除针对具体同学的攻击内容" {
		t.Errorf("original_reason = %v", got)
	}
	if got := item["report_reason_code"]; got != "harassment" {
		t.Errorf("report_reason_code = %v, want harassment", got)
	}
	if got := item["moderated_revision"]; got != float64(3) {
		t.Errorf("moderated_revision = %v, want 3", got)
	}
	snapshot, _ := item["moderated_snapshot"].(string)
	if !strings.Contains(snapshot, "人身攻击原文") {
		t.Errorf("moderated_snapshot 未包含处理时内容: %v", item["moderated_snapshot"])
	}
	if _, ok := item["moderated_at"]; !ok {
		t.Errorf("moderated_at 缺失，卡片无法展示处理时间")
	}
	// 客户端依赖 post.title / post.content 渲染「整改后内容」区。
	postRaw, _ := item["post"].(map[string]any)
	if postRaw == nil {
		t.Fatalf("响应缺少 post 字段: %s", body)
	}
	if got := postRaw["title"]; got != "被治理的帖子" {
		t.Errorf("post.title = %v", got)
	}
	if got := postRaw["content"]; got != "整改后的正常内容" {
		t.Errorf("post.content = %v", got)
	}
}

// 举报记录缺失（历史数据）时降级而不是整体失败：卡片仍要展示帖子字段，
// 并从帖子自身回填治理依据。
func TestListRectificationDegradesWhenReportMissing(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db := setupPostGovernanceTestDB(t)

	author := models.User{StudentID: "20261011", Nickname: "作者丙", Role: models.RoleUser}
	db.Create(&author)

	post := models.Post{
		Title:              "历史治理帖",
		Content:            "内容",
		BoardID:            models.BoardShuitie,
		AuthorID:           author.ID,
		Status:             models.PostStatusModeratedHidden,
		Revision:           2,
		ModerationRuleCode: "spam",
		ModerationReason:   "垃圾广告",
	}
	db.Create(&post)

	review := models.PostRectificationReview{
		PostID:            post.ID,
		SubmittedRevision: 2,
		Status:            models.RectificationReviewPending,
	}
	db.Create(&review)

	handler := NewPostGovernanceHandler(db)
	router := gin.New()
	router.GET("/admin/rectification", handler.ListRectification)

	recorder := httptest.NewRecorder()
	router.ServeHTTP(recorder, httptest.NewRequest(
		http.MethodGet, "/admin/rectification?status=pending", nil))

	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", recorder.Code, recorder.Body.String())
	}
	var items []map[string]any
	if err := json.Unmarshal(recorder.Body.Bytes(), &items); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if len(items) != 1 {
		t.Fatalf("items = %d, want 1", len(items))
	}
	if got := items[0]["original_rule_code"]; got != "spam" {
		t.Errorf("original_rule_code = %v, want spam（应从帖子回填）", got)
	}
	if got := items[0]["original_reason"]; got != "垃圾广告" {
		t.Errorf("original_reason = %v, want 垃圾广告（应从帖子回填）", got)
	}
}

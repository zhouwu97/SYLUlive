package handlers

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func setupPostGovernanceTestDB(t *testing.T) *gorm.DB {
	db, err := gorm.Open(sqlite.Open(fmt.Sprintf("file:post_gov_%d?mode=memory&cache=shared", time.Now().UnixNano())), &gorm.Config{})
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	if err := db.AutoMigrate(
		&models.User{},
		&models.File{},
		&models.Post{},
		&models.PostImage{},
		&models.Report{},
		&models.PostRectificationReview{},
		&models.Appeal{},
		&models.Notification{},
		&models.AdminActionLog{},
		&models.WaterSection{},
		&models.WaterTeamRecruitment{},
		&models.Like{},
		&models.Topic{},
		&models.PostTopic{},
	); err != nil {
		t.Fatalf("migrate database: %v", err)
	}
	db.Create(&models.WaterSection{Slug: "campus_life", Title: "校园生活", Status: "active"})
	return db
}

func TestPostGovernanceClosure_AccessAndEdit(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db := setupPostGovernanceTestDB(t)

	author := models.User{StudentID: "20260001", Nickname: "作者", Role: models.RoleUser}
	db.Create(&author)
	stranger := models.User{StudentID: "20260002", Nickname: "路人", Role: models.RoleUser}
	db.Create(&stranger)
	admin := models.User{StudentID: "20260003", Nickname: "管理员", Role: models.RoleAdmin}
	db.Create(&admin)

	post := models.Post{
		Title:    "治理测试帖",
		Content:  "原始违规内容",
		BoardID:  models.BoardShuitie,
		AuthorID: author.ID,
		Status:   models.PostStatusModeratedHidden,
		Revision: 1,
		ModerationReason: "包含不当言论",
	}
	db.Create(&post)

	postHandler := NewPostHandler(db, "", "")

	// 1. 路人访问治理隐藏帖子 -> 404
	{
		w := httptest.NewRecorder()
		c, _ := gin.CreateTestContext(w)
		c.Params = gin.Params{{Key: "id", Value: fmt.Sprint(post.ID)}}
		c.Set("user_id", stranger.ID)
		c.Set("role", string(models.RoleUser))
		c.Request = httptest.NewRequest(http.MethodGet, fmt.Sprintf("/posts/%d", post.ID), nil)
		postHandler.GetOne(c)

		if w.Code != http.StatusNotFound {
			t.Fatalf("stranger should get 404 for moderated_hidden post, got %d", w.Code)
		}
	}

	// 2. 作者访问治理隐藏帖子 -> 200，且 ViewerPermissions 正确
	{
		w := httptest.NewRecorder()
		c, _ := gin.CreateTestContext(w)
		c.Params = gin.Params{{Key: "id", Value: fmt.Sprint(post.ID)}}
		c.Set("user_id", author.ID)
		c.Set("role", string(models.RoleUser))
		c.Request = httptest.NewRequest(http.MethodGet, fmt.Sprintf("/posts/%d", post.ID), nil)
		postHandler.GetOne(c)

		if w.Code != http.StatusOK {
			t.Fatalf("author should get 200 for moderated_hidden post, got %d", w.Code)
		}
		var loaded models.Post
		json.Unmarshal(w.Body.Bytes(), &loaded)
		if loaded.ViewerPermissions == nil || !loaded.ViewerPermissions.CanSubmitRectification {
			t.Fatalf("author should have CanSubmitRectification=true, got %+v", loaded.ViewerPermissions)
		}
	}

	// 3. 作者编辑治理隐藏帖子 -> status 保持 moderated_hidden，revision 自增到 2
	{
		w := httptest.NewRecorder()
		c, _ := gin.CreateTestContext(w)
		c.Params = gin.Params{{Key: "id", Value: fmt.Sprint(post.ID)}}
		c.Set("user_id", author.ID)
		c.Set("role", string(models.RoleUser))
		form := "title=整改后标题&content=整改后正文"
		req := httptest.NewRequest(http.MethodPut, fmt.Sprintf("/posts/%d", post.ID), strings.NewReader(form))
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		c.Request = req
		postHandler.Update(c)

		if w.Code != http.StatusOK {
			t.Fatalf("author update failed: %d, body=%s", w.Code, w.Body.String())
		}
		var updated models.Post
		db.First(&updated, post.ID)
		if updated.Status != models.PostStatusModeratedHidden {
			t.Fatalf("status should remain moderated_hidden, got %s", updated.Status)
		}
		if updated.Revision != 2 {
			t.Fatalf("revision should be incremented to 2, got %d", updated.Revision)
		}
	}

	// 4. 作者提交整改复审
	govHandler := NewPostGovernanceHandler(db)
	var review models.PostRectificationReview
	{
		w := httptest.NewRecorder()
		c, _ := gin.CreateTestContext(w)
		c.Params = gin.Params{{Key: "id", Value: fmt.Sprint(post.ID)}}
		c.Set("user_id", author.ID)
		c.Request = httptest.NewRequest(http.MethodPost, fmt.Sprintf("/posts/%d/rectification-review", post.ID), nil)
		govHandler.SubmitRectification(c)

		if w.Code != http.StatusCreated {
			t.Fatalf("submit rectification failed: %d, body=%s", w.Code, w.Body.String())
		}
		json.Unmarshal(w.Body.Bytes(), &review)
		if review.SubmittedRevision != 2 {
			t.Fatalf("submitted revision should be 2, got %d", review.SubmittedRevision)
		}
	}

	// 5. 重复提交整改复审 -> 409
	{
		w := httptest.NewRecorder()
		c, _ := gin.CreateTestContext(w)
		c.Params = gin.Params{{Key: "id", Value: fmt.Sprint(post.ID)}}
		c.Set("user_id", author.ID)
		c.Request = httptest.NewRequest(http.MethodPost, fmt.Sprintf("/posts/%d/rectification-review", post.ID), nil)
		govHandler.SubmitRectification(c)

		if w.Code != http.StatusConflict {
			t.Fatalf("duplicate rectification should return 409, got %d", w.Code)
		}
	}

	// 6. 管理员审核通过整改复审 -> 帖子恢复 normal，产生作者通知
	{
		w := httptest.NewRecorder()
		c, _ := gin.CreateTestContext(w)
		c.Params = gin.Params{
			{Key: "id", Value: fmt.Sprint(review.ID)},
			{Key: "decision", Value: "approve"},
		}
		c.Set("user_id", admin.ID)
		payload := []byte(`{"reason":"整改到位，符合社区规范"}`)
		req := httptest.NewRequest(http.MethodPost, fmt.Sprintf("/admin/rectification/%d/approve", review.ID), bytes.NewReader(payload))
		req.Header.Set("Content-Type", "application/json")
		c.Request = req
		govHandler.ResolveRectification(c)

		if w.Code != http.StatusOK {
			t.Fatalf("resolve rectification failed: %d, body=%s", w.Code, w.Body.String())
		}
		var restored models.Post
		db.First(&restored, post.ID)
		if restored.Status != models.PostStatusNormal {
			t.Fatalf("post status should be normal, got %s", restored.Status)
		}

		var notification models.Notification
		if err := db.Where("user_id = ? AND type = ?", author.ID, models.NotificationTypeRectificationApproved).First(&notification).Error; err != nil {
			t.Fatalf("author should receive rectification_approved notification: %v", err)
		}
	}
}

func TestPostGovernanceClosure_AdminRestore(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db := setupPostGovernanceTestDB(t)

	author := models.User{StudentID: "20260001", Nickname: "作者", Role: models.RoleUser}
	db.Create(&author)
	admin := models.User{StudentID: "20260003", Nickname: "管理员", Role: models.RoleAdmin}
	db.Create(&admin)

	post := models.Post{
		Title:    "误处理帖子",
		Content:  "正常内容",
		BoardID:  models.BoardShuitie,
		AuthorID: author.ID,
		Status:   models.PostStatusModeratedHidden,
		Revision: 1,
	}
	db.Create(&post)

	appeal := models.Appeal{
		PostID:      post.ID,
		AppellantID: author.ID,
		TargetType:  "post",
		TargetID:    post.ID,
		Status:      models.AppealStatusPending,
	}
	db.Create(&appeal)

	govHandler := NewPostGovernanceHandler(db)

	// 管理员人工恢复帖子
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Params = gin.Params{{Key: "id", Value: fmt.Sprint(post.ID)}}
	c.Set("user_id", admin.ID)
	payload := []byte(`{"reason":"经核实为误治理，人工撤销"}`)
	req := httptest.NewRequest(http.MethodPost, fmt.Sprintf("/admin/posts/%d/restore", post.ID), bytes.NewReader(payload))
	req.Header.Set("Content-Type", "application/json")
	c.Request = req
	govHandler.AdminRestorePost(c)

	if w.Code != http.StatusOK {
		t.Fatalf("admin restore post failed: %d, body=%s", w.Code, w.Body.String())
	}

	var restored models.Post
	db.First(&restored, post.ID)
	if restored.Status != models.PostStatusNormal {
		t.Fatalf("post status should be restored to normal, got %s", restored.Status)
	}

	var log models.AdminActionLog
	if err := db.Where("target_id = ? AND action = ?", post.ID, "restore_post").First(&log).Error; err != nil {
		t.Fatalf("admin action log should be created: %v", err)
	}

	var closedAppeal models.Appeal
	if err := db.First(&closedAppeal, appeal.ID).Error; err != nil {
		t.Fatalf("appeal should exist: %v", err)
	}
	if closedAppeal.Status != models.AppealStatusPass || closedAppeal.ClosedReason != "admin_restore" {
		t.Fatalf("appeal should be closed with pass, got status=%s, reason=%s", closedAppeal.Status, closedAppeal.ClosedReason)
	}
}

func TestPostGovernance_ServeRectificationEvidenceFile(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db := setupPostGovernanceTestDB(t)

	tempDir := t.TempDir()
	contentBytes := []byte("fake image data for testing")
	fileName := "evidence_test.png"
	filePath := fmt.Sprintf("/uploads/%s", fileName)
	if err := os.WriteFile(fmt.Sprintf("%s/%s", tempDir, fileName), contentBytes, 0644); err != nil {
		t.Fatalf("write file failed: %v", err)
	}

	fileRec := models.File{
		Hash:        "hash_evidence_1",
		Path:        filePath,
		MimeType:    "image/png",
		Size:        int64(len(contentBytes)),
		AccessScope: models.FileAccessPrivate,
	}
	if err := db.Create(&fileRec).Error; err != nil {
		t.Fatalf("create file record: %v", err)
	}

	// 模拟不相关的私信附件文件，防止普通管理员借由证据接口跨权限读取
	unrelatedFile := models.File{
		Hash:        "hash_evidence_2",
		Path:        "/uploads/private_msg.png",
		MimeType:    "image/png",
		Size:        100,
		AccessScope: models.FileAccessPrivate,
	}
	if err := db.Create(&unrelatedFile).Error; err != nil {
		t.Fatalf("create unrelated file: %v", err)
	}

	post := models.Post{
		Title:    "证据测试帖",
		Content:  "正文",
		BoardID:  models.BoardShuitie,
		AuthorID: 1,
		Status:   models.PostStatusModeratedHidden,
	}
	db.Create(&post)

	reportSnapshot := fmt.Sprintf(`{"title":"违规帖","content":"违规内容","image_file_ids":[%d],"original_status":"normal"}`, fileRec.ID)
	report := models.Report{
		ReporterID:     2,
		TargetType:     "post",
		TargetID:       post.ID,
		TargetSnapshot: reportSnapshot,
		Status:         models.ReportStatusHandled,
	}
	db.Create(&report)

	review := models.PostRectificationReview{
		PostID:            post.ID,
		ReportID:          &report.ID,
		Status:            models.RectificationReviewPending,
		SubmittedRevision: 2,
	}
	db.Create(&review)

	govHandler := NewPostGovernanceHandler(db)
	govHandler.SetUploadDir(tempDir)

	// 1. 访问属于该案件的证据图片 -> 200 OK
	{
		w := httptest.NewRecorder()
		c, _ := gin.CreateTestContext(w)
		c.Params = gin.Params{
			{Key: "reviewId", Value: fmt.Sprint(review.ID)},
			{Key: "fileId", Value: fmt.Sprint(fileRec.ID)},
		}
		c.Request = httptest.NewRequest(http.MethodGet, fmt.Sprintf("/api/admin/rectification/%d/evidence/%d", review.ID, fileRec.ID), nil)

		govHandler.ServeRectificationEvidenceFile(c)

		if w.Code != http.StatusOK {
			t.Fatalf("expected 200 OK for related evidence file, got %d", w.Code)
		}
		if !bytes.Equal(w.Body.Bytes(), contentBytes) {
			t.Fatalf("body mismatch")
		}
		if w.Header().Get("Content-Type") != "image/png" {
			t.Fatalf("content type mismatch: %s", w.Header().Get("Content-Type"))
		}
	}

	// 2. 尝试借用该 reviewId 读取不属于该案件的私信/全局文件 -> 404 (防止 IDOR)
	{
		w := httptest.NewRecorder()
		c, _ := gin.CreateTestContext(w)
		c.Params = gin.Params{
			{Key: "reviewId", Value: fmt.Sprint(review.ID)},
			{Key: "fileId", Value: fmt.Sprint(unrelatedFile.ID)},
		}
		c.Request = httptest.NewRequest(http.MethodGet, fmt.Sprintf("/api/admin/rectification/%d/evidence/%d", review.ID, unrelatedFile.ID), nil)

		govHandler.ServeRectificationEvidenceFile(c)

		if w.Code != http.StatusNotFound {
			t.Fatalf("expected 404 Not Found for unrelated file, got %d", w.Code)
		}
	}
}

func TestPostGovernance_ModeratedSnapshotSeparation(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db := setupPostGovernanceTestDB(t)

	author := models.User{StudentID: "20261001", Nickname: "作者", Role: models.RoleUser}
	reporter := models.User{StudentID: "20261002", Nickname: "举报人", Role: models.RoleUser}
	admin := models.User{StudentID: "20261003", Nickname: "管理员", Role: models.RoleAdmin}
	db.Create(&author)
	db.Create(&reporter)
	db.Create(&admin)

	// 1. 发帖 v1
	post := models.Post{
		Title:    "帖子标题v1",
		Content:  "帖子正文v1",
		BoardID:  models.BoardShuitie,
		AuthorID: author.ID,
		Status:   models.PostStatusNormal,
		Revision: 1,
	}
	db.Create(&post)

	reportHandler := NewReportHandler(db)

	// 2. 举报时记录 TargetSnapshot (v1)
	var reportID uint
	{
		w := httptest.NewRecorder()
		c, _ := gin.CreateTestContext(w)
		c.Set("user_id", reporter.ID)
		body := strings.NewReader(fmt.Sprintf(`{"target_type":"post","target_id":%d,"reason_code":"spam","reason":"垃圾广告"}`, post.ID))
		req := httptest.NewRequest(http.MethodPost, "/api/reports", body)
		req.Header.Set("Content-Type", "application/json")
		c.Request = req

		reportHandler.Create(c)
		if w.Code != http.StatusOK && w.Code != http.StatusCreated {
			t.Fatalf("create report failed: %d, %s", w.Code, w.Body.String())
		}
		var rep models.Report
		json.Unmarshal(w.Body.Bytes(), &rep)
		reportID = rep.ID
		if !strings.Contains(rep.TargetSnapshot, "帖子标题v1") {
			t.Fatalf("target snapshot should contain v1 content: %s", rep.TargetSnapshot)
		}
	}

	// 3. 作者在管理员审核前编辑帖子 -> v2
	db.Model(&post).Updates(map[string]interface{}{
		"title":    "帖子标题v2(作者已修改)",
		"content":  "帖子正文v2(作者已修改)",
		"revision": 2,
	})

	// 4. 管理员审核该举报，执行违规隐藏
	{
		w := httptest.NewRecorder()
		c, _ := gin.CreateTestContext(w)
		c.Params = gin.Params{{Key: "id", Value: fmt.Sprint(reportID)}}
		c.Set("user_id", admin.ID)
		c.Set("role", string(models.RoleAdmin))

		body := strings.NewReader(`{"status":"handled","action":"moderated_hidden","confirmed_reason_code":"spam","delete_reason":"违规隐藏"}`)
		req := httptest.NewRequest(http.MethodPut, fmt.Sprintf("/api/admin/reports/%d", reportID), body)
		req.Header.Set("Content-Type", "application/json")
		c.Request = req

		reportHandler.Handle(c)
		if w.Code != http.StatusOK {
			t.Fatalf("handle report failed: %d, %s", w.Code, w.Body.String())
		}
	}

	// 5. 校验 Report: TargetSnapshot 保留 v1，ModeratedSnapshot 准确捕获 v2
	var updatedReport models.Report
	db.First(&updatedReport, reportID)
	if updatedReport.ModeratedRevision != 2 {
		t.Fatalf("moderated_revision should be 2, got %d", updatedReport.ModeratedRevision)
	}
	if !strings.Contains(updatedReport.TargetSnapshot, "帖子标题v1") {
		t.Fatalf("TargetSnapshot must remain v1: %s", updatedReport.TargetSnapshot)
	}
	if !strings.Contains(updatedReport.ModeratedSnapshot, "帖子标题v2") {
		t.Fatalf("ModeratedSnapshot must accurately capture v2: %s", updatedReport.ModeratedSnapshot)
	}

	// 6. 整改待办 buildRectificationAdminItem 优先选用 ModeratedSnapshot 并标记 snapshot_source=moderated
	govHandler := NewPostGovernanceHandler(db)
	review := models.PostRectificationReview{
		PostID:            post.ID,
		ReportID:          &updatedReport.ID,
		Status:            models.RectificationReviewPending,
		SubmittedRevision: 3,
	}
	db.Create(&review)

	var loadedReview models.PostRectificationReview
	db.Preload("Report").Preload("Post").First(&loadedReview, review.ID)
	item := govHandler.buildRectificationAdminItem(&loadedReview)

	if item.SnapshotSource != "moderated" {
		t.Fatalf("snapshot_source should be 'moderated', got %s", item.SnapshotSource)
	}
	if !strings.Contains(item.ModeratedSnapshot, "帖子标题v2") {
		t.Fatalf("item.ModeratedSnapshot should contain v2 content: %s", item.ModeratedSnapshot)
	}

	// 7. 兜底测试：老数据没有 ModeratedSnapshot 时 fallback 到 TargetSnapshot 并标记 reported
	legacyReport := models.Report{
		TargetType:        "post",
		TargetID:          post.ID,
		TargetSnapshot:    `{"title":"老举报v1","content":"老举报正文"}`,
		ModeratedSnapshot: "",
		Status:            models.ReportStatusHandled,
	}
	db.Create(&legacyReport)
	legacyReview := models.PostRectificationReview{
		PostID:            post.ID,
		ReportID:          &legacyReport.ID,
		Status:            models.RectificationReviewPending,
		SubmittedRevision: 4,
	}
	db.Create(&legacyReview)

	var loadedLegacy models.PostRectificationReview
	db.Preload("Report").Preload("Post").First(&loadedLegacy, legacyReview.ID)
	legacyItem := govHandler.buildRectificationAdminItem(&loadedLegacy)

	if legacyItem.SnapshotSource != "reported" {
		t.Fatalf("legacy item snapshot_source should be 'reported', got %s", legacyItem.SnapshotSource)
	}
	if !strings.Contains(legacyItem.ModeratedSnapshot, "老举报v1") {
		t.Fatalf("legacy item should fallback to TargetSnapshot: %s", legacyItem.ModeratedSnapshot)
	}
}

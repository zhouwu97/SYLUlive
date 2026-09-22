package handlers

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/middleware"
	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

// newPollContractRouter 复刻 main.go 的投票路由挂载：
// 公开读取走可选鉴权，发布/编辑挂社区规则门禁，投票/关闭/删除不挂。
func newPollContractRouter(db *gorm.DB) *gin.Engine {
	gin.SetMode(gin.TestMode)
	handler := NewPollHandler(db)
	router := gin.New()
	public := router.Group("/api/polls", middleware.OptionalAuthMiddleware(db, "secret"))
	public.GET("", handler.List)
	public.GET("/:id", handler.Get)
	auth := router.Group("/api/polls", middleware.AuthMiddleware(db, "secret"))
	auth.POST("", middleware.RequireCommunityRules(db), handler.Create)
	auth.PUT("/:id", middleware.RequireCommunityRules(db), handler.Update)
	auth.DELETE("/:id", handler.Delete)
	auth.PUT("/:id/ballot", handler.PutBallot)
	auth.POST("/:id/close", handler.Close)
	return router
}

func newPollContractDB(t *testing.T) (*gorm.DB, models.User, models.User) {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(filepath.Join(t.TempDir(), "poll-visibility.db")), &gorm.Config{})
	if err != nil {
		t.Fatal(err)
	}
	sqlDB, err := db.DB()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = sqlDB.Close() })
	if err := db.AutoMigrate(&models.User{}, &models.File{}, &models.Post{}, &models.PostImage{},
		&models.ImageVariant{}, &models.Poll{}, &models.PollOption{},
		&models.PollBallot{}, &models.PollBallotChoice{}, &models.UserLegalConsent{}); err != nil {
		t.Fatal(err)
	}
	author := models.User{StudentID: "poll-contract-author", PasswordHash: "hash", Nickname: "发起人"}
	voter := models.User{StudentID: "poll-contract-voter", PasswordHash: "hash", Nickname: "投票人"}
	for _, user := range []*models.User{&author, &voter} {
		if err := db.Create(user).Error; err != nil {
			t.Fatal(err)
		}
		middleware.InvalidateTokenVersionCache(user.ID)
		t.Cleanup(func() { middleware.InvalidateTokenVersionCache(user.ID) })
	}
	return db, author, voter
}

// seedContractPoll 建立一条挂在指定帖子状态上的进行中投票，返回帖子 ID、投票 ID 与选项 ID。
func seedContractPoll(t *testing.T, db *gorm.DB, authorID uint, status models.PostStatus) (uint, uint, []uint) {
	t.Helper()
	now := time.Now()
	post := models.Post{
		Title: "契约测试投票", Content: "说明", BoardID: models.BoardShuitie, AuthorID: authorID,
		PostType: "poll", ContentKind: models.PostContentKindPoll, Status: status,
		CreatedAt: now, LastActivityAt: now,
	}
	if err := db.Create(&post).Error; err != nil {
		t.Fatal(err)
	}
	poll := models.Poll{
		PostID: post.ID, Category: models.PollCategoryOther, SelectionMode: models.PollSelectionSingle,
		MaxChoices: 1, ResultsVisibility: models.PollResultsAlways, AllowChange: true,
		IsAnonymous: true, Status: models.PollStatusActive, EndsAt: now.Add(time.Hour),
	}
	if err := db.Create(&poll).Error; err != nil {
		t.Fatal(err)
	}
	options := []models.PollOption{
		{PollID: poll.ID, Text: "赞成", SortOrder: 0},
		{PollID: poll.ID, Text: "反对", SortOrder: 1},
	}
	if err := db.Create(&options).Error; err != nil {
		t.Fatal(err)
	}
	optionIDs := make([]uint, 0, len(options))
	for _, option := range options {
		optionIDs = append(optionIDs, option.ID)
	}
	return post.ID, poll.ID, optionIDs
}

func doPollContractRequest(t *testing.T, router *gin.Engine, token, method, path, body string) *httptest.ResponseRecorder {
	t.Helper()
	var reader *strings.Reader = strings.NewReader("")
	if body != "" {
		reader = strings.NewReader(body)
	}
	req := httptest.NewRequest(method, path, reader)
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	recorder := httptest.NewRecorder()
	router.ServeHTTP(recorder, req)
	return recorder
}

func pollContractToken(t *testing.T, db *gorm.DB, user models.User) string {
	t.Helper()
	token, err := middleware.GenerateToken(user.ID, string(models.RoleUser), user.TokenVersion, "secret")
	if err != nil {
		t.Fatal(err)
	}
	return token
}

// acceptBaseLegalConsents 只补签基础协议（用户协议 + 隐私政策），
// 不写入社区规则的独立确认，用来验证门禁确实落在投票入口上。
func acceptBaseLegalConsents(t *testing.T, db *gorm.DB, userID uint) {
	t.Helper()
	now := time.Now()
	for _, document := range []string{models.LegalDocumentUserAgreement, models.LegalDocumentPrivacyPolicy} {
		consent := models.UserLegalConsent{
			UserID: userID, Document: document, Version: models.LegalDocumentVersion,
			AcknowledgementType: "separate_consent", AcceptedAt: now,
		}
		if err := db.Create(&consent).Error; err != nil {
			t.Fatal(err)
		}
	}
}

// TestPollHTTPRejectsNonPublicPostStatus 覆盖 A02：帖子被治理隐藏、删除或进入
// 未来新增的未知状态后，投票详情与写入都必须按不存在处理，不能因为
// "投票自身的 status 还是 active" 就继续可读可投。
func TestPollHTTPRejectsNonPublicPostStatus(t *testing.T) {
	for _, status := range []models.PostStatus{
		models.PostStatusModeratedHidden,
		models.PostStatusDeleted,
		models.PostStatus("quarantined_by_future_policy"),
	} {
		t.Run(string(status), func(t *testing.T) {
			db, author, voter := newPollContractDB(t)
			_, pollID, optionIDs := seedContractPoll(t, db, author.ID, status)
			router := newPollContractRouter(db)
			token := pollContractToken(t, db, voter)
			authorToken := pollContractToken(t, db, author)
			body, err := json.Marshal(map[string]any{"option_ids": optionIDs[:1]})
			if err != nil {
				t.Fatal(err)
			}

			detail := doPollContractRequest(t, router, token, http.MethodGet, "/api/polls/1", "")
			if detail.Code != http.StatusNotFound {
				t.Fatalf("非公开帖子 %s 的投票详情 status=%d body=%s", status, detail.Code, detail.Body.String())
			}
			ballot := doPollContractRequest(t, router, token, http.MethodPut, "/api/polls/1/ballot", string(body))
			if ballot.Code != http.StatusNotFound {
				t.Fatalf("非公开帖子 %s 仍可投票 status=%d body=%s", status, ballot.Code, ballot.Body.String())
			}
			close := doPollContractRequest(t, router, authorToken, http.MethodPost, "/api/polls/1/close", "")
			if close.Code != http.StatusNotFound {
				t.Fatalf("非公开帖子 %s 仍可关闭 status=%d body=%s", status, close.Code, close.Body.String())
			}
			// 投票 API 不提供"作者/管理员看隐藏帖"的特权分支：隐藏语义由帖子详情承担，
			// 否则投票入口会变成治理隐藏的旁路。
			var ballots int64
			if err := db.Model(&models.PollBallot{}).Where("poll_id = ?", pollID).Count(&ballots).Error; err != nil {
				t.Fatal(err)
			}
			if ballots != 0 {
				t.Fatalf("非公开帖子 %s 仍写入 %d 张选票", status, ballots)
			}
		})
	}
}

// TestPollHTTPIsPublicForWhitelistedStatus 确认白名单内的状态仍可正常读取和投票，
// 避免修复把公开投票一起挡掉。
func TestPollHTTPIsPublicForWhitelistedStatus(t *testing.T) {
	db, author, voter := newPollContractDB(t)
	_, pollID, optionIDs := seedContractPoll(t, db, author.ID, models.PostStatusNormal)
	router := newPollContractRouter(db)
	token := pollContractToken(t, db, voter)
	body, err := json.Marshal(map[string]any{"option_ids": optionIDs[:1]})
	if err != nil {
		t.Fatal(err)
	}
	if got := doPollContractRequest(t, router, token, http.MethodGet, "/api/polls/1", ""); got.Code != http.StatusOK {
		t.Fatalf("公开投票详情 status=%d body=%s", got.Code, got.Body.String())
	}
	if got := doPollContractRequest(t, router, token, http.MethodPut, "/api/polls/1/ballot", string(body)); got.Code != http.StatusOK {
		t.Fatalf("公开投票写入 status=%d body=%s", got.Code, got.Body.String())
	}
	var ballots int64
	if err := db.Model(&models.PollBallot{}).Where("poll_id = ?", pollID).Count(&ballots).Error; err != nil {
		t.Fatal(err)
	}
	if ballots != 1 {
		t.Fatalf("公开投票写入选票 = %d", ballots)
	}
}

// TestPollListAndDetailShareVisibilityWhitelist 确认列表与详情用同一套状态白名单：
// sold/closed 的投票在两处都可见，moderated_hidden 在两处都不可见，
// 避免出现"列表里没有但按 ID 仍可投票"或反之的缝隙。
func TestPollListAndDetailShareVisibilityWhitelist(t *testing.T) {
	db, author, voter := newPollContractDB(t)
	postID, _, optionIDs := seedContractPoll(t, db, author.ID, models.PostStatusClosed)
	router := newPollContractRouter(db)
	token := pollContractToken(t, db, voter)
	body, err := json.Marshal(map[string]any{"option_ids": optionIDs[:1]})
	if err != nil {
		t.Fatal(err)
	}
	var list struct {
		Items []struct {
			ID uint `json:"id"`
		} `json:"items"`
		Total int64 `json:"total"`
	}
	listResponse := doPollContractRequest(t, router, token, http.MethodGet, "/api/polls?sort=latest", "")
	if listResponse.Code != http.StatusOK {
		t.Fatalf("投票列表 status=%d body=%s", listResponse.Code, listResponse.Body.String())
	}
	if err := json.Unmarshal(listResponse.Body.Bytes(), &list); err != nil {
		t.Fatal(err)
	}
	if list.Total != 1 || len(list.Items) != 1 || list.Items[0].ID != postID {
		t.Fatalf("closed 投票未同时进入列表与总数: %s", listResponse.Body.String())
	}
	if got := doPollContractRequest(t, router, token, http.MethodGet, "/api/polls/1", ""); got.Code != http.StatusOK {
		t.Fatalf("closed 投票详情 status=%d body=%s", got.Code, got.Body.String())
	}
	if got := doPollContractRequest(t, router, token, http.MethodPut, "/api/polls/1/ballot", string(body)); got.Code != http.StatusOK {
		t.Fatalf("closed 投票写入 status=%d body=%s", got.Code, got.Body.String())
	}
	if _, hiddenPollID, _ := seedContractPoll(t, db, author.ID, models.PostStatusModeratedHidden); hiddenPollID == 0 {
		t.Fatal("隐藏投票种子失败")
	}
	listOnlyPublic := doPollContractRequest(t, router, token, http.MethodGet, "/api/polls?sort=latest", "")
	if err := json.Unmarshal(listOnlyPublic.Body.Bytes(), &list); err != nil {
		t.Fatal(err)
	}
	if list.Total != 1 || len(list.Items) != 1 {
		t.Fatalf("治理隐藏的投票进入了列表: %s", listOnlyPublic.Body.String())
	}
	if got := doPollContractRequest(t, router, token, http.MethodGet, "/api/polls/2", ""); got.Code != http.StatusNotFound {
		t.Fatalf("治理隐藏的投票仍可按 ID 读取 status=%d body=%s", got.Code, got.Body.String())
	}
}

// TestPollCommunityRulesGateCoversOnlyPublishAndEdit 覆盖 A05 的门禁挂载范围：
// 只有发布与编辑需要先行确认社区规则，投票、关闭、删除不能被门禁误伤。
func TestPollCommunityRulesGateCoversOnlyPublishAndEdit(t *testing.T) {
	middleware.SetLegalConsentEnforcement(middleware.LegalConsentEnforcementHard)
	t.Cleanup(func() { middleware.SetLegalConsentEnforcement(middleware.LegalConsentEnforcementSoft) })
	db, author, voter := newPollContractDB(t)
	_, _, optionIDs := seedContractPoll(t, db, author.ID, models.PostStatusNormal)
	router := newPollContractRouter(db)
	acceptBaseLegalConsents(t, db, voter.ID)
	acceptBaseLegalConsents(t, db, author.ID)
	token := pollContractToken(t, db, voter)
	authorToken := pollContractToken(t, db, author)
	createBody := `{"title":"新的契约投票","category":"other","selection_mode":"single","max_choices":1,"results_visibility":"always","allow_change":true,"ends_at":"` +
		time.Now().Add(time.Hour).Format(time.RFC3339) + `","options":["赞成","反对"]}`
	ballotBody, err := json.Marshal(map[string]any{"option_ids": optionIDs[:1]})
	if err != nil {
		t.Fatal(err)
	}

	unconfirmed := doPollContractRequest(t, router, token, http.MethodPost, "/api/polls", createBody)
	if unconfirmed.Code != http.StatusForbidden {
		t.Fatalf("未确认社区规则的发布未被拦截 status=%d body=%s", unconfirmed.Code, unconfirmed.Body.String())
	}
	if !strings.Contains(unconfirmed.Body.String(), "community_rules_required") {
		t.Fatalf("未确认社区规则返回了业务错误: %s", unconfirmed.Body.String())
	}
	edited := doPollContractRequest(t, router, authorToken, http.MethodPut, "/api/polls/1", createBody)
	if edited.Code != http.StatusForbidden {
		t.Fatalf("未确认社区规则的编辑未被拦截 status=%d body=%s", edited.Code, edited.Body.String())
	}
	// 已登录但未确认规则的用户仍然可以参与、关闭和删除既有投票。
	if got := doPollContractRequest(t, router, token, http.MethodPut, "/api/polls/1/ballot", string(ballotBody)); got.Code != http.StatusOK {
		t.Fatalf("门禁误伤投票 status=%d body=%s", got.Code, got.Body.String())
	}
	if got := doPollContractRequest(t, router, authorToken, http.MethodPost, "/api/polls/1/close", ""); got.Code != http.StatusOK {
		t.Fatalf("门禁误伤关闭 status=%d body=%s", got.Code, got.Body.String())
	}
	if got := doPollContractRequest(t, router, authorToken, http.MethodDelete, "/api/polls/1", ""); got.Code != http.StatusOK {
		t.Fatalf("门禁误伤删除 status=%d body=%s", got.Code, got.Body.String())
	}
}

// TestPollWriteRejectedAfterPostHiddenByGovernance 复核治理隐藏落地后的读写：
// 帖子一旦转为 moderated_hidden，投票写入与编辑必须在事务内被当前状态挡住，
// 不能依赖"更早的列表快照认为它还公开"。
func TestPollWriteRejectedAfterPostHiddenByGovernance(t *testing.T) {
	db, author, voter := newPollContractDB(t)
	postID, pollID, optionIDs := seedContractPoll(t, db, author.ID, models.PostStatusNormal)
	service := services.NewPollService(db)
	if _, err := service.PutBallot(pollID, voter.ID, optionIDs[:1]); err != nil {
		t.Fatalf("公开投票写入失败: %v", err)
	}
	if err := db.Model(&models.Post{}).Where("id = ?", postID).Update("status", models.PostStatusModeratedHidden).Error; err != nil {
		t.Fatal(err)
	}
	if _, err := service.PutBallot(pollID, voter.ID, optionIDs[1:]); err == nil {
		t.Fatal("帖子隐藏后仍可改票")
	}
	if _, err := service.Update(pollID, author.ID, string(models.RoleUser), services.CreatePollInput{
		Title: "改名", Category: models.PollCategoryOther, SelectionMode: models.PollSelectionSingle,
		MaxChoices: 1, ResultsVisibility: models.PollResultsAlways, EndsAt: time.Now().Add(time.Hour),
		Options: []string{"赞成", "反对"},
	}); err == nil {
		t.Fatal("帖子隐藏后仍可编辑投票")
	}
}

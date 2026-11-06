package handlers

import (
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
	"shenliyuan/internal/middleware"
	"shenliyuan/internal/models"
)

// Opt-in network acceptance. Its only community is an empty loopback SQLite fixture.
func TestIntegrationRealAIManagedBotRuntime(t *testing.T) {
	if os.Getenv("SYLULIVE_REAL_AI_TEST") != "1" {
		t.Skip("real model requests require explicit SYLULIVE_REAL_AI_TEST=1 and isolated fixture configuration")
	}
	python := os.Getenv("SYLULIVE_REAL_AI_PYTHON")
	require.NotEmpty(t, python)
	require.NotEmpty(t, os.Getenv("SYLULIVE_REAL_AI_CONFIG_PATH"))
	require.NotEmpty(t, os.Getenv("SYLULIVE_REAL_AI_EVIDENCE_DIR"))
	db, err := gorm.Open(sqlite.Open("file:"+uuid.NewString()+"?mode=memory&cache=shared"), &gorm.Config{Logger: logger.Discard})
	require.NoError(t, err)
	pool, err := db.DB()
	require.NoError(t, err)
	pool.SetMaxOpenConns(1)
	t.Cleanup(func() {
		_ = pool.Close()
		middleware.InvalidateTokenVersionCache(129001)
		middleware.InvalidateTokenVersionCache(129002)
	})
	require.NoError(t, db.AutoMigrate(&models.User{}, &models.UserLegalConsent{}, &models.AcademicIdentityBinding{}, &models.RefreshToken{},
		&models.IntegrationBinding{}, &models.IntegrationCredential{}, &models.IntegrationDeviceRequest{}, &models.IntegrationAction{},
		&models.IntegrationAudit{}, &models.IntegrationRateBucket{}, &models.Post{}, &models.Reply{}, &models.WaterSection{}, &models.WaterSectionMute{},
		&models.ManagedBot{}, &models.Notification{}, &models.File{}, &models.PostImage{}, &models.ReplyImage{}, &models.FileUploadGrant{}, &models.ImageVariant{}))
	const secret = "synthetic-real-ai-loopback-jwt-secret"
	r := gin.New()
	jwtValues := []string{}
	for i, owner := range []uint{129001, 129002} {
		require.NoError(t, db.Create(&models.User{ID: owner, Nickname: fmt.Sprintf("真实模型验收合成用户%d", i+1), Role: models.RoleUser, AccountStatus: "active"}).Error)
		require.NoError(t, db.Create(&models.AcademicIdentityBinding{UserID: owner, ProviderID: models.AcademicProviderUndergraduate,
			StudentID: fmt.Sprintf("20990000%02d", i+1), VerifiedAt: time.Now(), VerificationMethod: "school_profile", VerificationVersion: "v1", BindingVersion: 1}).Error)
		for _, doc := range []string{models.LegalDocumentUserAgreement, models.LegalDocumentPrivacyPolicy, models.LegalDocumentCommunityRules} {
			ack := ""
			if doc == models.LegalDocumentCommunityRules {
				ack = "rules_acceptance"
			}
			require.NoError(t, db.Create(&models.UserLegalConsent{UserID: owner, Document: doc, Version: models.LegalDocumentVersion, AcceptedAt: time.Now(), AcknowledgementType: ack}).Error)
		}
		c, _ := gin.CreateTestContext(httptest.NewRecorder())
		c.Request = httptest.NewRequest("POST", "/api/login", nil)
		_, family, err := issueRefreshSessionForDB(db, owner, c)
		require.NoError(t, err)
		token, err := middleware.GenerateToken(owner, string(models.RoleUser), 0, secret, family)
		require.NoError(t, err)
		jwtValues = append(jwtValues, token)
	}
	require.NoError(t, db.Create(&models.WaterSection{Slug: "course_study", Title: "学习交流", Status: "active"}).Error)
	seeds := []struct{ title, content string }{
		{"学习计划交流：课多时怎样安排复习", "这是隔离测试社区的一篇合成帖子。本周课比较满，晚自习总想同时做很多事情，结果经常学不完。想听听同学们怎样拆分复习任务、安排休息，并用简单的方法检查自己是否真正理解。欢迎分享具体、可执行的建议。"},
		{"学习经验分享：把错题整理变成复习工具", "隔离测试用合成帖子：我试过把错题只记结论，过几天还是会错。后来改成先写错误原因，再不看答案重做，并隔几天回顾一次。这样整理更少，但更容易发现薄弱环节。大家还有什么适合课余时间的学习方法？"},
	}
	for i, seed := range seeds {
		post := models.Post{AuthorID: 129001, Title: seed.title, Content: seed.content, Contact: "TEST_PRIVATE_CONTACT_CANARY_MUST_NOT_REACH_MODEL", PostType: "course_study", BoardID: models.BoardShuitie, Status: models.PostStatusNormal, ContentKind: models.PostContentKindNormal}
		require.NoError(t, db.Create(&post).Error)
		require.NoError(t, db.Create(&models.Reply{PostID: post.ID, AuthorID: 129002, Content: fmt.Sprintf("合成讨论%d：我也希望看到能坚持一周的具体安排，尤其是如何在学习和休息之间取得平衡。", i+1)}).Error)
	}
	h := NewIntegrationHandler(db, IntegrationOptions{ProposalsEnabled: true, AutoReplyEnabled: true, AutoPostEnabled: true})
	h.Register(r, secret)
	// Fixture-only route: seed a human thread on the real model's newly created post.
	// It exists only in this disposable loopback test server, never production routing.
	r.POST("/__fixture/thread-human", middleware.AuthMiddleware(db, secret), func(c *gin.Context) {
		if c.GetUint("user_id") != 129002 {
			c.Status(403)
			return
		}
		var bot models.ManagedBot
		require.NoError(t, db.Where("owner_id = ?", 129002).Take(&bot).Error)
		var own models.Post
		require.NoError(t, db.Where("author_id = ?", bot.UserID).Order("id DESC").Take(&own).Error)
		root := models.Reply{PostID: own.ID, AuthorID: 129001, Content: "谢谢分享这个学习方法。", Status: models.ReplyStatusNormal}
		require.NoError(t, db.Create(&root).Error)
		target := models.Reply{PostID: own.ID, AuthorID: 129001, ParentReplyID: &root.ID, ReplyToReplyID: &root.ID, Content: "想继续问楼中楼：如果每天只有二十分钟，怎么挑出最该复习的两个知识点？请针对这个问题给一个简单步骤。", Status: models.ReplyStatusNormal}
		require.NoError(t, db.Create(&target).Error)
		c.JSON(200, gin.H{"post_id": own.ID, "root_reply_id": root.ID, "target_reply_id": target.ID})
	})
	server := httptest.NewServer(r)
	defer server.Close()
	h.options.PublicOrigin = server.URL
	root, err := filepath.Abs("../../..")
	require.NoError(t, err)
	cmd := exec.Command(python, filepath.Join(root, "scripts", "verify_real_ai_runtime.py"))
	cmd.Dir = root
	cmd.Env = append(os.Environ(), "SYLULIVE_FULL_CHAIN_ORIGIN="+server.URL, "SYLULIVE_REAL_AI_FIRST_JWT="+jwtValues[0], "SYLULIVE_REAL_AI_SECOND_JWT="+jwtValues[1],
		"PYTHONUTF8=1", "ASTRBOT_ROOT="+t.TempDir(), "PYTHONPATH="+root)
	output, runErr := cmd.CombinedOutput()
	// Python prints allowlisted result metadata only, never credentials or raw exceptions.
	require.NoError(t, runErr, string(output))
	lines := strings.Split(strings.TrimSpace(string(output)), "\n")
	result := map[string]any{}
	require.NoError(t, json.Unmarshal([]byte(lines[len(lines)-1]), &result), string(output))
	require.Equal(t, true, result["passed"], string(output))
	botIDs := []uint{}
	for i, owner := range []uint{129001, 129002} {
		var bot models.ManagedBot
		require.NoError(t, db.Where("owner_id = ?", owner).Take(&bot).Error)
		botIDs = append(botIDs, bot.UserID)
		var posts []models.Post
		var replies []models.Reply
		require.NoError(t, db.Where("author_id = ?", bot.UserID).Find(&posts).Error)
		require.NoError(t, db.Where("author_id = ?", bot.UserID).Find(&replies).Error)
		if i == 0 {
			require.Len(t, replies, 1)
			require.Empty(t, posts)
			require.NotEmpty(t, replies[0].Content)
		} else {
			require.Len(t, posts, 1)
			require.Len(t, replies, 1)
			require.NotNil(t, replies[0].ReplyToReplyID)
			require.NotNil(t, replies[0].ParentReplyID)
			var human models.Reply
			require.NoError(t, db.First(&human, *replies[0].ReplyToReplyID).Error)
			require.EqualValues(t, 129001, human.AuthorID)
			require.Equal(t, human.ParentReplyID, replies[0].ParentReplyID)
			require.Equal(t, posts[0].ID, replies[0].PostID)
			require.NotEmpty(t, posts[0].Content)
		}
	}
	require.NotEqual(t, botIDs[0], botIDs[1])
	t.Log(lines[len(lines)-1])
}

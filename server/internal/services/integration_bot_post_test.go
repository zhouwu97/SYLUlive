package services

import (
	"context"
	"encoding/json"
	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"
	"os"
	"path/filepath"
	"shenliyuan/internal/community"
	"shenliyuan/internal/models"
	"sync"
	"testing"
	"time"
)

func permitBotPosts(t *testing.T, db *gorm.DB, owner uint) {
	t.Helper()
	policy := DefaultManagedBotPolicy()
	policy.PostEnabled = true
	policy.ImageEnabled = true
	raw, err := json.Marshal(policy)
	require.NoError(t, err)
	require.NoError(t, db.Model(&models.ManagedBot{}).Where("owner_id = ?", owner).Update("policy_json", string(raw)).Error)
}

func TestIntegrationBotPostRespectsCurrentOwnerPolicy(t *testing.T) {
	for _, mode := range []string{"legacy", "read_off", "post_off", "image_off", "blocked_title", "link", "source_section", "paused", "daily_quota"} {
		t.Run(mode, func(t *testing.T) {
			db, s, b, source := integrationActionFixture(t)
			require.NoError(t, db.AutoMigrate(&models.ManagedBot{}, &models.File{}, &models.FileUploadGrant{}, &models.PostImage{}, &models.ImageVariant{}))
			bot, err := s.ManageBot(context.Background(), b.OwnerID, "合成权限机器人", true)
			require.NoError(t, err)
			b.Scopes += " " + IntegrationAutoPostScope
			require.NoError(t, db.Save(&b).Error)
			policy := DefaultManagedBotPolicy()
			policy.PostEnabled = true
			policy.ImageEnabled = true
			p := IntegrationProposal{OperationID: uuid.NewString(), Kind: "post", Title: "公开测试", Content: "合成讨论", PostType: source.PostType}
			switch mode {
			case "legacy":
				policy.PostEnabled = false
				policy.ImageEnabled = false
			case "read_off":
				policy.PublicReadEnabled = false
			case "post_off":
				policy.PostEnabled = false
			case "image_off":
				policy.ImageEnabled = false
				p.ImageFileIDs = []uint{999}
			case "blocked_title":
				policy.BlockedTerms = []string{"禁止词"}
				p.Title = "禁\u200b止词"
			case "link":
				p.Content = "https://example.invalid/"
			case "source_section":
				policy.AllowedPostTypes = []string{source.PostType}
				require.NoError(t, db.Create(&models.WaterSection{Slug: "course_study", Title: "课程学习", Status: "active"}).Error)
				source.PostType = "course_study"
				require.NoError(t, db.Save(&source).Error)
			case "paused":
				require.NoError(t, db.Model(&bot).Update("enabled", false).Error)
			}
			p.Sources = []IntegrationPostSource{{source.ID, community.PostDTO(source, 10000).SourceVersion}}
			raw, err := json.Marshal(policy)
			require.NoError(t, err)
			require.NoError(t, db.Model(&bot).Update("policy_json", string(raw)).Error)
			var originalCount int64
			require.NoError(t, db.Model(&models.Post{}).Where("author_id = ?", bot.UserID).Count(&originalCount).Error)
			if mode == "daily_quota" {
				_, err = s.AutoPost(context.Background(), b, p)
				require.NoError(t, err)
				p.OperationID = uuid.NewString()
				originalCount++
			}
			_, err = s.AutoPost(context.Background(), b, p)
			require.Error(t, err)
			var count int64
			require.NoError(t, db.Model(&models.Post{}).Where("author_id = ?", bot.UserID).Count(&count).Error)
			require.Equal(t, originalCount, count)
		})
	}
}

func TestIntegrationBotPostSeparateScopeOwnImagesActorAndReplay(t *testing.T) {
	db, s, b, source := integrationActionFixture(t)
	require.NoError(t, db.AutoMigrate(&models.ManagedBot{}, &models.File{}, &models.FileUploadGrant{}, &models.PostImage{}, &models.ImageVariant{}))
	root := t.TempDir()
	t.Setenv("UPLOAD_DIR", root)
	bot, err := s.ManageBot(context.Background(), b.OwnerID, "合成校园助手", true)
	require.NoError(t, err)
	permitBotPosts(t, db, b.OwnerID)
	file := models.File{Hash: "synthetic-bot-picture", Path: "/uploads/picture.png", MimeType: "image/png", UploaderID: bot.UserID, AccessScope: models.FileAccessPrivate, Status: models.FileStatusTemporary}
	require.NoError(t, os.WriteFile(filepath.Join(root, "picture.png"), []byte("synthetic image"), 0600))
	require.NoError(t, db.Create(&file).Error)
	p := IntegrationProposal{OperationID: uuid.NewString(), Kind: "post", Title: "合成校园分享", Content: "合成机器人帖子", PostType: source.PostType, ImageFileIDs: []uint{file.ID}, Sources: []IntegrationPostSource{{source.ID, community.PostDTO(source, 10000).SourceVersion}}}
	b.Scopes += " " + IntegrationAutoReplyScope
	require.NoError(t, db.Save(&b).Error)
	_, err = s.AutoPost(context.Background(), b, p)
	require.EqualError(t, err, "insufficient_scope", "评论授权不能变成发帖/上传授权")
	b.Scopes += " " + IntegrationAutoPostScope
	require.NoError(t, db.Save(&b).Error)
	actor, err := s.BotUploadActor(context.Background(), b)
	require.NoError(t, err)
	require.Equal(t, bot.UserID, actor)
	a, err := s.AutoPost(context.Background(), b, p)
	require.NoError(t, err)
	require.Equal(t, "published", a.State)
	var created models.Post
	require.NoError(t, db.First(&created, *a.PostID).Error)
	require.Equal(t, bot.UserID, created.AuthorID)
	require.Contains(t, created.Content, "[AI机器人]")
	var link models.PostImage
	require.NoError(t, db.First(&link, "post_id = ?", created.ID).Error)
	require.Equal(t, file.ID, link.FileID)
	require.NoError(t, db.First(&file, file.ID).Error)
	require.Equal(t, models.FileAccessPublic, file.AccessScope)
	repeat, err := s.AutoPost(context.Background(), b, p)
	require.NoError(t, err)
	require.Equal(t, a.PostID, repeat.PostID)
	p.OperationID = uuid.NewString()
	_, err = s.AutoPost(context.Background(), b, p)
	require.EqualError(t, err, "bot_post_daily_quota")
}

func TestIntegrationBotPostConcurrentOperationPublishesOnce(t *testing.T) {
	db, s, b, source := integrationActionFixture(t)
	require.NoError(t, db.AutoMigrate(&models.ManagedBot{}))
	_, err := s.ManageBot(context.Background(), b.OwnerID, "合成校园助手", true)
	require.NoError(t, err)
	permitBotPosts(t, db, b.OwnerID)
	b.Scopes += " " + IntegrationAutoPostScope
	require.NoError(t, db.Save(&b).Error)
	p := IntegrationProposal{OperationID: uuid.NewString(), Kind: "post", Content: "合成并发机器人帖子", PostType: source.PostType, Sources: []IntegrationPostSource{{source.ID, community.PostDTO(source, 10000).SourceVersion}}}
	var wg sync.WaitGroup
	results := make(chan models.IntegrationAction, 6)
	errors := make(chan error, 6)
	for i := 0; i < 6; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); a, e := s.AutoPost(context.Background(), b, p); results <- a; errors <- e }()
	}
	wg.Wait()
	close(results)
	close(errors)
	for e := range errors {
		require.NoError(t, e)
	}
	var postID uint
	for a := range results {
		require.Equal(t, "published", a.State)
		if postID == 0 {
			postID = *a.PostID
		}
		require.Equal(t, postID, *a.PostID)
	}
	var count int64
	require.NoError(t, db.Model(&models.Post{}).Where("id <> ?", source.ID).Count(&count).Error)
	require.EqualValues(t, 1, count)
}

func TestIntegrationBotPostBlocksForeignPublicImageDeletedSourceAndRevocation(t *testing.T) {
	for _, mode := range []string{"foreign_public_image", "deleted_source", "revoked", "manual_route", "manual_text_route", "stale_source", "missing_sources"} {
		t.Run(mode, func(t *testing.T) {
			db, s, b, source := integrationActionFixture(t)
			require.NoError(t, db.AutoMigrate(&models.ManagedBot{}, &models.File{}, &models.FileUploadGrant{}, &models.PostImage{}, &models.ImageVariant{}))
			_, err := s.ManageBot(context.Background(), b.OwnerID, "合成校园助手", true)
			require.NoError(t, err)
			permitBotPosts(t, db, b.OwnerID)
			b.Scopes += " " + IntegrationAutoPostScope
			require.NoError(t, db.Save(&b).Error)
			p := IntegrationProposal{OperationID: uuid.NewString(), Kind: "post", Content: "合成校园记录", PostType: source.PostType, Sources: []IntegrationPostSource{{source.ID, community.PostDTO(source, 10000).SourceVersion}}}
			switch mode {
			case "foreign_public_image", "manual_route":
				root := t.TempDir()
				t.Setenv("UPLOAD_DIR", root)
				require.NoError(t, os.WriteFile(filepath.Join(root, "other.png"), []byte("synthetic"), 0600))
				file := models.File{Hash: uuid.NewString(), Path: "/uploads/other.png", MimeType: "image/png", UploaderID: 999, AccessScope: models.FileAccessPublic}
				require.NoError(t, db.Create(&file).Error)
				p.ImageFileIDs = []uint{file.ID}
			case "deleted_source":
				require.NoError(t, db.Model(&source).Update("status", models.PostStatusModeratedHidden).Error)
			case "revoked":
				require.NoError(t, s.Auth.Revoke(context.Background(), b.OwnerID, b.ID))
			case "stale_source":
				p.Sources[0].Version = IntegrationSecretHash("old-version")
			case "missing_sources":
				p.Sources = nil
			}
			if mode == "manual_route" || mode == "manual_text_route" {
				a, e := s.Propose(context.Background(), b, p)
				require.NoError(t, e)
				d := integrationDecision(t, s, a)
				_, err = s.Decide(context.Background(), b.OwnerID, a.ID, d)
			} else {
				_, err = s.AutoPost(context.Background(), b, p)
			}
			require.Error(t, err)
			var count int64
			require.NoError(t, db.Model(&models.Post{}).Where("id <> ? AND created_at > ?", source.ID, time.Time{}).Count(&count).Error)
			require.Zero(t, count)
		})
	}
}

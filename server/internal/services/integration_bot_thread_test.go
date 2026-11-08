package services

import (
	"context"
	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm/clause"
	"os"
	"shenliyuan/internal/community"
	"shenliyuan/internal/models"
	"sync"
	"testing"
	"time"
)

func TestIntegrationBotRepliesToHumanTargetsOnItsOwnPost(t *testing.T) {
	db, s, b, post := integrationActionFixture(t)
	require.NoError(t, db.AutoMigrate(&models.ManagedBot{}))
	ctx := context.Background()
	bot, err := s.ManageBot(ctx, 1, "鱼", true)
	require.NoError(t, err)
	grantBotParticipation(t, db, bot)
	b.Scopes += " " + IntegrationAutoReplyScope
	require.NoError(t, db.Save(&b).Error)
	require.NoError(t, db.Model(&post).Update("author_id", bot.UserID).Error)
	now := time.Now()
	s.Auth.Now = func() time.Time { return now }
	// Valid pre-upgrade data: older bots could leave a top-level comment on their own post.
	legacy := models.Reply{PostID: post.ID, AuthorID: bot.UserID, Content: "历史顶层参与", Status: models.ReplyStatusNormal, CreatedAt: now}
	require.NoError(t, db.Create(&legacy).Error)
	root := models.Reply{PostID: post.ID, AuthorID: 1, Content: "这个收纳建议怎么实施？", Status: models.ReplyStatusNormal}
	require.NoError(t, db.Create(&root).Error)
	proposal := func(target models.Reply) IntegrationProposal {
		p := integrationReplyProposal(post)
		p.ReplyToReplyID, p.ReplySourceVersion = target.ID, community.ReplyDTO(target).SourceVersion
		return p
	}
	now = now.Add(31 * time.Minute)
	p := proposal(root)
	action, err := s.AutoReply(ctx, b, p)
	require.NoError(t, err)
	var actual models.Reply
	require.NoError(t, db.First(&actual, *action.ReplyID).Error)
	require.Equal(t, bot.UserID, actual.AuthorID)
	require.Equal(t, &root.ID, actual.ParentReplyID)
	require.Equal(t, &root.ID, actual.ReplyToReplyID)
	require.Equal(t, &root.AuthorID, actual.ReplyToUserID)
	repeated, err := s.AutoReply(ctx, b, p)
	require.NoError(t, err)
	require.Equal(t, action.ReplyID, repeated.ReplyID)
	now = now.Add(31 * time.Minute)
	require.NoError(t, db.Model(&actual).Update("status", models.ReplyStatusDeleted).Error)
	p.OperationID = uuid.NewString()
	_, err = s.AutoReply(ctx, b, p)
	require.EqualError(t, err, "bot_reply_already_answered")
	nested := models.Reply{PostID: post.ID, AuthorID: 1, ParentReplyID: &root.ID, ReplyToReplyID: &actual.ID, Content: "谢谢，还能详细讲讲吗？", Status: models.ReplyStatusNormal}
	require.NoError(t, db.Create(&nested).Error)
	second, err := s.AutoReply(ctx, b, proposal(nested))
	require.NoError(t, err)
	actual = models.Reply{}
	require.NoError(t, db.First(&actual, *second.ReplyID).Error)
	require.Equal(t, &root.ID, actual.ParentReplyID)
	require.Equal(t, &nested.ID, actual.ReplyToReplyID)
	now = now.Add(31 * time.Minute)
	another := nested
	another.ID = 0
	require.NoError(t, db.Create(&another).Error)
	_, err = s.AutoReply(ctx, b, proposal(another))
	require.EqualError(t, err, "bot_daily_quota")
}

func TestIntegrationBotHumanReplyTargetSafety(t *testing.T) {
	for _, kind := range []string{"self", "other_bot", "edited", "deleted", "cross_post", "cooldown"} {
		t.Run(kind, func(t *testing.T) {
			db, s, b, post := integrationActionFixture(t)
			require.NoError(t, db.AutoMigrate(&models.ManagedBot{}))
			ctx := context.Background()
			bot, err := s.ManageBot(ctx, 1, "鱼", true)
			require.NoError(t, err)
			grantBotParticipation(t, db, bot)
			b.Scopes += " " + IntegrationAutoReplyScope
			require.NoError(t, db.Save(&b).Error)
			target := models.Reply{PostID: post.ID, AuthorID: 1, Content: "真实人类评论", Status: models.ReplyStatusNormal}
			if kind == "self" {
				target.AuthorID = bot.UserID
			}
			if kind == "other_bot" {
				other := models.User{Nickname: "普通昵称", AccountStatus: "bot", Role: models.RoleUser}
				require.NoError(t, db.Create(&other).Error)
				require.NoError(t, db.Create(&models.ManagedBot{OwnerID: 55, UserID: other.ID}).Error)
				target.AuthorID = other.ID
			}
			if kind == "cross_post" {
				target.PostID++
			}
			require.NoError(t, db.Create(&target).Error)
			p := integrationReplyProposal(post)
			p.ReplyToReplyID, p.ReplySourceVersion = target.ID, community.ReplyDTO(target).SourceVersion
			expected := "bot_reply_target_not_human"
			if kind == "edited" {
				require.NoError(t, db.Model(&target).Update("content", "变化后正文").Error)
				expected = "source_changed"
			}
			if kind == "deleted" {
				require.NoError(t, db.Model(&target).Update("status", models.ReplyStatusDeleted).Error)
				expected = "source_unavailable"
			}
			if kind == "cross_post" {
				expected = "source_unavailable"
			}
			if kind == "cooldown" {
				_, err := s.AutoReply(ctx, b, integrationReplyProposal(post))
				require.NoError(t, err)
				expected = "bot_reply_cooldown"
			}
			_, err = s.AutoReply(ctx, b, p)
			require.EqualError(t, err, expected)
		})
	}
}

func TestIntegrationBotConcurrentHumanTargetIsAnsweredOnce(t *testing.T) {
	db, s, b, post := integrationActionFixture(t)
	require.NoError(t, db.AutoMigrate(&models.ManagedBot{}))
	ctx := context.Background()
	bot, err := s.ManageBot(ctx, 1, "鱼", true)
	require.NoError(t, err)
	grantBotParticipation(t, db, bot)
	b.Scopes += " " + IntegrationAutoReplyScope
	require.NoError(t, db.Save(&b).Error)
	target := models.Reply{PostID: post.ID, AuthorID: 1, Content: "请回复这个问题", Status: models.ReplyStatusNormal}
	require.NoError(t, db.Create(&target).Error)
	var group sync.WaitGroup
	results := make(chan error, 4)
	for i := 0; i < 4; i++ {
		group.Add(1)
		go func() {
			defer group.Done()
			p := integrationReplyProposal(post)
			p.ReplyToReplyID, p.ReplySourceVersion = target.ID, community.ReplyDTO(target).SourceVersion
			_, err := s.AutoReply(ctx, b, p)
			results <- err
		}()
	}
	group.Wait()
	close(results)
	success := 0
	for err := range results {
		if err == nil {
			success++
		} else {
			require.EqualError(t, err, "bot_reply_already_answered")
		}
	}
	require.Equal(t, 1, success)
	var count int64
	require.NoError(t, db.Model(&models.Reply{}).Where("author_id = ? AND reply_to_reply_id = ?", bot.UserID, target.ID).Count(&count).Error)
	require.EqualValues(t, 1, count)
}

func TestIntegrationBotDeletedTargetCannotRacePublicationPostgres(t *testing.T) {
	if os.Getenv("INTEGRATION_TEST_POSTGRES_DSN") == "" {
		t.Skip("requires disposable loopback PostgreSQL")
	}
	db, s, b, post := integrationActionFixture(t)
	require.NoError(t, db.AutoMigrate(&models.ManagedBot{}))
	bot, err := s.ManageBot(context.Background(), 1, "鱼", true)
	require.NoError(t, err)
	grantBotParticipation(t, db, bot)
	b.Scopes += " " + IntegrationAutoReplyScope
	require.NoError(t, db.Save(&b).Error)
	target := models.Reply{PostID: post.ID, AuthorID: 1, Content: "将被删除的真实问题", Status: models.ReplyStatusNormal}
	require.NoError(t, db.Create(&target).Error)
	p := integrationReplyProposal(post)
	p.ReplyToReplyID, p.ReplySourceVersion = target.ID, community.ReplyDTO(target).SourceVersion
	tx := db.Begin()
	require.NoError(t, tx.Error)
	defer tx.Rollback()
	var locked models.Post
	require.NoError(t, tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&locked, post.ID).Error)
	require.NoError(t, tx.Model(&target).Update("status", models.ReplyStatusDeleted).Error)
	done := make(chan error, 1)
	go func() { _, err := s.AutoReply(context.Background(), b, p); done <- err }()
	require.Eventually(t, func() bool {
		var count int64
		err := db.Raw("SELECT count(*) FROM pg_stat_activity WHERE pid <> pg_backend_pid() AND wait_event_type = 'Lock' AND query LIKE '%FROM \"posts\"%' AND query LIKE '%FOR NO KEY UPDATE%'").Scan(&count).Error
		return err == nil && count > 0
	}, 5*time.Second, 20*time.Millisecond)
	require.NoError(t, tx.Commit().Error)
	select {
	case err := <-done:
		require.EqualError(t, err, "source_unavailable")
	case <-time.After(5 * time.Second):
		t.Fatal("target deletion must finish without publication or deadlock")
	}
	var count int64
	require.NoError(t, db.Model(&models.Reply{}).Where("author_id = ?", bot.UserID).Count(&count).Error)
	require.Zero(t, count)
}

func TestIntegrationBotTopLevelTargetsOnlyHumanPosts(t *testing.T) {
	for _, kind := range []string{"own_bot", "other_bot", "human_ai_nickname"} {
		t.Run(kind, func(t *testing.T) {
			db, s, b, post := integrationActionFixture(t)
			require.NoError(t, db.AutoMigrate(&models.ManagedBot{}))
			ctx := context.Background()
			bot, err := s.ManageBot(ctx, 1, "鱼", true)
			require.NoError(t, err)
			grantBotParticipation(t, db, bot)
			b.Scopes += " " + IntegrationAutoReplyScope
			require.NoError(t, db.Save(&b).Error)
			if kind == "own_bot" {
				require.NoError(t, db.Model(&post).Update("author_id", bot.UserID).Error)
			}
			if kind == "other_bot" {
				other := models.User{Nickname: "无AI标识昵称", AccountStatus: "bot", Role: models.RoleUser}
				require.NoError(t, db.Create(&other).Error)
				require.NoError(t, db.Create(&models.ManagedBot{OwnerID: 55, UserID: other.ID}).Error)
				require.NoError(t, db.Model(&post).Update("author_id", other.ID).Error)
			}
			if kind == "human_ai_nickname" {
				require.NoError(t, db.Model(&models.User{}).Where("id = ?", 1).Update("nickname", "[AI] 自称AI").Error)
			}
			_, err = s.AutoReply(ctx, b, integrationReplyProposal(post))
			if kind == "human_ai_nickname" {
				require.NoError(t, err)
			} else {
				require.EqualError(t, err, "bot_reply_target_not_human")
			}
		})
	}
}

package services

import (
	"context"
	"testing"

	"github.com/stretchr/testify/require"
	"shenliyuan/internal/academiccalendar"
	"shenliyuan/internal/models"
)

func TestManagedBotEarnsPublishAndHumanLikeExp(t *testing.T) {
	require.NoError(t, academiccalendar.InitializeTimezone())
	db, s, b, post := integrationActionFixture(t)
	require.NoError(t, db.AutoMigrate(&models.ManagedBot{}, &models.ExpLog{}))
	ctx := context.Background()
	bot, err := s.ManageBot(ctx, 1, "大肥鱼", true)
	require.NoError(t, err)
	grantBotParticipation(t, db, bot)
	b.Scopes += " " + IntegrationAutoReplyScope
	require.NoError(t, db.Save(&b).Error)
	_, err = s.AutoReply(ctx, b, integrationReplyProposal(post))
	require.NoError(t, err)

	exp := func() int {
		var u models.User
		require.NoError(t, db.Select("exp").First(&u, bot.UserID).Error)
		return u.Exp
	}
	require.Equal(t, GlobalExpReplyDaily, exp(), "机器人每日首评与用户一样获得经验")

	// 创建者本人点赞不计，其他人点赞/取消对称增减，且不低于 0。
	require.NoError(t, ApplyManagedBotLikeExp(db, bot.UserID, 1, 1))
	require.Equal(t, GlobalExpReplyDaily, exp())
	require.NoError(t, ApplyManagedBotLikeExp(db, bot.UserID, 99, 1))
	require.Equal(t, GlobalExpReplyDaily+ManagedBotLikeExp, exp())
	require.NoError(t, ApplyManagedBotLikeExp(db, bot.UserID, 99, -1))
	require.NoError(t, ApplyManagedBotLikeExp(db, bot.UserID, 99, -1))
	require.NoError(t, ApplyManagedBotLikeExp(db, bot.UserID, 99, -1))
	require.Equal(t, 0, exp())

	// 普通用户不受影响。
	require.NoError(t, ApplyManagedBotLikeExp(db, 1, 99, 1))
	var owner models.User
	require.NoError(t, db.Select("exp").First(&owner, 1).Error)
	require.Equal(t, 0, owner.Exp)
}

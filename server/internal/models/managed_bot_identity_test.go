package models

import (
	"encoding/json"
	"path/filepath"
	"testing"

	"github.com/glebarez/sqlite"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"
)

func TestManagedBotPublicIdentityUsesServerOwnership(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(filepath.Join(t.TempDir(), "identity.db")), &gorm.Config{})
	require.NoError(t, err)
	sqlDB, err := db.DB()
	require.NoError(t, err)
	t.Cleanup(func() { _ = sqlDB.Close() })
	require.NoError(t, db.AutoMigrate(&User{}, &ManagedBot{}))
	owner := User{Nickname: "创建者", PasswordHash: "secret-sentinel", Email: "private@example.invalid", StudentID: "private-school-id"}
	bot := User{Nickname: "[AI] 鱼", PasswordHash: "!bot", AccountStatus: "bot"}
	fake := User{Nickname: "[AI] 假标记", PasswordHash: "!human"}
	require.NoError(t, db.Create(&owner).Error)
	require.NoError(t, db.Create(&bot).Error)
	require.NoError(t, db.Create(&fake).Error)
	require.NoError(t, db.Create(&ManagedBot{OwnerID: owner.ID, UserID: bot.ID}).Error)

	var found User
	require.NoError(t, db.First(&found, bot.ID).Error)
	require.Equal(t, &PublicBotIdentity{OwnerID: owner.ID, OwnerNickname: "创建者"}, found.AIBot)
	body, err := json.Marshal(Reply{ID: 7, Author: found})
	require.NoError(t, err)
	require.Contains(t, string(body), `"ai_bot":{"owner_id":`)
	for _, secret := range []string{"private@example.invalid", "private-school-id", "secret-sentinel", "password_hash", "student_id", "email"} {
		require.NotContains(t, string(body), secret)
	}
	found = User{}
	require.NoError(t, db.First(&found, fake.ID).Error)
	require.Nil(t, found.AIBot, "昵称不能伪造系统归属")
	require.NoError(t, db.Model(&owner).Update("nickname", "新昵称").Error)
	found = User{}
	require.NoError(t, db.First(&found, bot.ID).Error)
	require.Equal(t, "新昵称", found.AIBot.OwnerNickname)
	require.NoError(t, db.Model(&owner).Update("account_status", "cancelled").Error)
	require.NoError(t, db.First(&found, bot.ID).Error)
	require.Equal(t, &PublicBotIdentity{}, found.AIBot, "注销后只保留AI标记，不发布旧创建者身份")
}

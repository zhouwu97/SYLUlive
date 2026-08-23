package main

import (
	"testing"
	"time"

	"github.com/glebarez/sqlite"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func TestEnsureUserCalendarAgentActionUniqueIndexPreflightsAndIsIdempotent(t *testing.T) {
	db, err := gorm.Open(sqlite.Open("file:calendar-action-migration?mode=memory&cache=shared"), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(&models.UserCalendarEvent{}, &models.UserCalendarActionMigrationConflict{}))

	base := models.UserCalendarEvent{
		UserID: 7, CalendarID: 1, Title: "重复动作", StartAt: time.Now(), EndAt: time.Now().Add(time.Hour),
		Timezone: "Asia/Shanghai", SourceType: models.UserCalendarSourceAgentAction, SourceID: "draft-7",
	}
	require.NoError(t, db.Create(&base).Error)
	duplicate := base
	duplicate.ID = 0
	require.NoError(t, db.Create(&duplicate).Error)

	err = ensureUserCalendarAgentActionUniqueIndex(db)
	require.Error(t, err)
	require.Contains(t, err.Error(), "请先显式去重")
	var conflict models.UserCalendarActionMigrationConflict
	require.NoError(t, db.Where("user_id = ? AND source_id = ?", 7, "draft-7").First(&conflict).Error)
	require.Equal(t, 2, conflict.DuplicateCount)

	require.NoError(t, db.Unscoped().Delete(&duplicate).Error)
	require.NoError(t, ensureUserCalendarAgentActionUniqueIndex(db))
	require.NoError(t, ensureUserCalendarAgentActionUniqueIndex(db))
}

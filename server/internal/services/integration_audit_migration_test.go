package services

import (
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
	"shenliyuan/internal/models"
)

type integrationLegacyAudit struct {
	ID        uint64    `gorm:"primaryKey"`
	OwnerID   uint      `gorm:"index;not null"`
	BindingID string    `gorm:"size:36;index"`
	ActionID  string    `gorm:"size:36"`
	Event     string    `gorm:"size:40;not null"`
	CreatedAt time.Time `gorm:"index"`
}

func (integrationLegacyAudit) TableName() string { return "integration_audits" }

func TestIntegrationAuditMigrationPreservesLegacyRecordsAndOldReader(t *testing.T) {
	// helper只创建本机专用测试schema或内存SQLite，绝不复用已有业务表。
	db := integrationTestDB(t)
	require.NoError(t, db.Migrator().DropTable(&models.IntegrationAudit{}))
	require.NoError(t, db.AutoMigrate(&integrationLegacyAudit{}))
	before := integrationLegacyAudit{OwnerID: 1, BindingID: uuid.NewString(), Event: "authorized", CreatedAt: time.Date(2026, 10, 31, 0, 0, 0, 0, time.UTC)}
	require.NoError(t, db.Create(&before).Error)
	require.NoError(t, db.AutoMigrate(&models.IntegrationAudit{}))
	require.True(t, db.Migrator().HasColumn(&models.IntegrationAudit{}, "actor_id"))
	require.True(t, db.Migrator().HasColumn(&models.IntegrationAudit{}, "reason"))
	var after models.IntegrationAudit
	require.NoError(t, db.First(&after, before.ID).Error)
	require.Equal(t, before.BindingID, after.BindingID)
	require.Equal(t, before.Event, after.Event)
	require.Zero(t, after.ActorID)
	require.Empty(t, after.Reason)
	require.NoError(t, db.AutoMigrate(&models.IntegrationAudit{}))
	var oldReader integrationLegacyAudit
	require.NoError(t, db.First(&oldReader, before.ID).Error)
	require.Equal(t, before.ID, oldReader.ID)
	require.Equal(t, before.OwnerID, oldReader.OwnerID)
	require.Equal(t, before.BindingID, oldReader.BindingID)
	require.Equal(t, before.Event, oldReader.Event)
	require.True(t, before.CreatedAt.Equal(oldReader.CreatedAt))
}

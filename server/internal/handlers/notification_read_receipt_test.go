package handlers

import (
	"bytes"
	"encoding/json"
	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"
	"net/http/httptest"
	"shenliyuan/internal/models"
	"testing"
)

func TestNotificationReadReceiptIsAccountScoped(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(&models.Notification{}))
	require.NoError(t, db.Create(&[]models.Notification{
		{ID: 1, UserID: 7, Type: "reply", RelatedID: 11},
		{ID: 2, UserID: 8, Type: "reply", RelatedID: 12},
		{ID: 3, UserID: 7, Type: "reply", RelatedID: 13},
	}).Error)
	request := func(all bool) map[string]interface{} {
		w := httptest.NewRecorder()
		c, _ := gin.CreateTestContext(w)
		c.Set("user_id", uint(7))
		c.Request = httptest.NewRequest("POST", "/notifications/read-selected", bytes.NewBufferString(`{"ids":[1,2]}`))
		c.Request.Header.Set("Content-Type", "application/json")
		h := NewNotificationHandler(db)
		if all {
			h.MarkAllRead(c)
		} else {
			h.MarkSelectedRead(c)
		}
		require.Equal(t, 200, w.Code)
		body := map[string]interface{}{}
		require.NoError(t, json.Unmarshal(w.Body.Bytes(), &body))
		return body["read_receipt"].(map[string]interface{})
	}
	receipt := request(false)
	require.EqualValues(t, 7, receipt["recipient_user_id"])
	require.Equal(t, []interface{}{float64(1)}, receipt["ids"])
	require.Equal(t, []interface{}{float64(11)}, receipt["reply_ids"])
	all := request(true)
	require.EqualValues(t, 3, all["all_before_id"])
	var other models.Notification
	require.NoError(t, db.First(&other, 2).Error)
	require.False(t, other.IsRead)
	fresh := models.Notification{UserID: 7, Type: "reply", RelatedID: 14}
	require.NoError(t, db.Create(&fresh).Error)
	require.Greater(t, fresh.ID, uint(3))
	require.False(t, fresh.IsRead)
}

func TestNotificationReadByReplyOnlyConsumesMatchingOwnedReply(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(&models.Notification{}))
	require.NoError(t, db.Create(&[]models.Notification{
		{ID: 1, UserID: 7, Type: "reply", PostID: 100, RelatedID: 11},
		{ID: 2, UserID: 8, Type: "reply", PostID: 100, RelatedID: 11},
		{ID: 3, UserID: 7, Type: "reply", PostID: 101, RelatedID: 11},
		{ID: 4, UserID: 7, Type: "reply", PostID: 100, RelatedID: 12},
		{ID: 5, UserID: 7, Type: "announcement", PostID: 100, RelatedID: 11},
	}).Error)
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Set("user_id", uint(7))
	c.Request = httptest.NewRequest("POST", "/notifications/read-selected", bytes.NewBufferString(`{"post_id":100,"reply_id":11}`))
	c.Request.Header.Set("Content-Type", "application/json")
	NewNotificationHandler(db).MarkSelectedRead(c)
	require.Equal(t, 200, w.Code)
	body := map[string]interface{}{}
	require.NoError(t, json.Unmarshal(w.Body.Bytes(), &body))
	receipt := body["read_receipt"].(map[string]interface{})
	require.Equal(t, []interface{}{float64(1)}, receipt["ids"])
	var rows []models.Notification
	require.NoError(t, db.Order("id").Find(&rows).Error)
	for _, row := range rows {
		require.Equal(t, row.ID == 1, row.IsRead, "notification %d", row.ID)
	}
}

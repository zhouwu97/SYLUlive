package handlers

import (
	"fmt"
	"log"
	"net/http"

	"shenliyuan/internal/models"
	"shenliyuan/utils"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
)

// NotificationHandler 通知处理器
type NotificationHandler struct {
	db *gorm.DB
}

// NewNotificationHandler 创建通知处理器
func NewNotificationHandler(db *gorm.DB) *NotificationHandler {
	return &NotificationHandler{db: db}
}

// GetUnreadCount 获取未读通知数量（红点用）
func (h *NotificationHandler) GetUnreadCount(c *gin.Context) {
	userID, _ := c.Get("user_id")
	uid := userID.(uint)

	var count int64
	h.db.Model(&models.Notification{}).Where("user_id = ? AND is_read = ?", uid, false).Count(&count)

	c.JSON(http.StatusOK, gin.H{
		"count": count,
	})
}

// GetNotifications 获取所有类型的通知列表
func (h *NotificationHandler) GetNotifications(c *gin.Context) {
	userID, _ := c.Get("user_id")
	uid := userID.(uint)

	var notifications []models.Notification
	if err := h.db.Where("user_id = ?", uid).
		Order("created_at desc").
		Limit(100).
		Find(&notifications).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取通知失败"})
		return
	}

	type UserInfo struct {
		ID       uint   `json:"id"`
		Nickname string `json:"nickname"`
		Avatar   string `json:"avatar"`
	}

	type NotificationRes struct {
		models.Notification
		FromUser *UserInfo `json:"from_user"`
	}

	var res []NotificationRes
	for _, n := range notifications {
		item := NotificationRes{Notification: n}
		if n.FromUID > 0 {
			var u models.User
			if h.db.Where("id = ?", n.FromUID).Select("id, nickname, avatar").First(&u).Error == nil {
				item.FromUser = &UserInfo{ID: u.ID, Nickname: u.Nickname, Avatar: u.Avatar}
			}
		}
		res = append(res, item)
	}

	c.JSON(http.StatusOK, res)
}

// MarkAllRead 将所有通知标记为已读
func (h *NotificationHandler) MarkAllRead(c *gin.Context) {
	userID, _ := c.Get("user_id")
	uid := userID.(uint)

	if err := h.db.Model(&models.Notification{}).Where("user_id = ? AND is_read = ?", uid, false).Update("is_read", true).Error; err != nil {
		log.Printf("[DB_WARN] Failed to write side-effect record: %v", err)
	}

	c.JSON(http.StatusOK, gin.H{"message": "已全部标记为已读"})
}

// CreateReplyNotification 创建回复通知（被 reply handler 调用）
func CreateReplyNotification(db *gorm.DB, toUserID, fromUserID, replyID, postID uint, content string) {
	if toUserID == fromUserID {
		return // 不通知自己
	}
	notification := models.Notification{
		UserID:    toUserID,
		Type:      "reply",
		Content:   content,
		RelatedID: replyID,
		PostID:    postID,
		FromUID:   fromUserID,
		IsRead:    false,
	}
	db.Create(&notification)
}

// SendJPushNotification 异步发送极光推送（不阻塞主请求）
func SendJPushNotification(jpushAppKey, jpushMasterSecret string, db *gorm.DB, toUserID, fromUserID uint, replyID, postID uint, content string) {
	if jpushAppKey == "" || jpushMasterSecret == "" {
		return
	}
	if toUserID == fromUserID {
		return
	}

	var user models.User
	if err := db.Where("id = ?", toUserID).Select("id, nickname, device_token").First(&user).Error; err != nil {
		return
	}
	if user.DeviceToken == "" {
		return
	}

	var fromUser models.User
	if err := db.Where("id = ?", fromUserID).Select("nickname").First(&fromUser).Error; err != nil {
		return
	}

	contentPreview := content
	if len(contentPreview) > 50 {
		contentPreview = contentPreview[:50] + "..."
	}

	go func() {
		jpush := utils.NewJPushClient(jpushAppKey, jpushMasterSecret)
		extras := map[string]interface{}{
			"post_id":  postID,
			"reply_id": replyID,
			"type":     "reply",
		}
		title := "您有新的回复"
		alert := fmt.Sprintf("%s: %s", fromUser.Nickname, contentPreview)
		if err := jpush.SendNotification(user.DeviceToken, title, alert, extras); err != nil {
			fmt.Printf("JPush send failed: %v\n", err)
		}
	}()
}

// CreateReplyNotificationFull 创建回复通知并触发极光推送
func CreateReplyNotificationFull(jpushAppKey, jpushMasterSecret string, db *gorm.DB, toUserID, fromUserID, replyID, postID uint, content string) {
	CreateReplyNotification(db, toUserID, fromUserID, replyID, postID, content)
	SendJPushNotification(jpushAppKey, jpushMasterSecret, db, toUserID, fromUserID, replyID, postID, content)
}

// CreateMarketPostNotification 集市发帖通知（发给所有用户，除了作者自己）
func CreateMarketPostNotification(db *gorm.DB, postID uint, title string, price float64, authorID uint) {
	var users []models.User
	if err := db.Select("id").Where("id != ?", authorID).Find(&users).Error; err != nil {
		log.Printf("[DB_WARN] CreateMarketPostNotification Find users failed: %v", err)
		return
	}

	titlePreview := title
	if len(titlePreview) > 50 {
		titlePreview = titlePreview[:50] + "..."
	}
	content := titlePreview
	if price > 0 {
		content = fmt.Sprintf("%s  ¥%.2f", titlePreview, price)
	}

	for _, user := range users {
		notification := models.Notification{
			UserID:    user.ID,
			Type:      "market_post",
			Content:   content,
			RelatedID: postID,
			PostID:    postID,
			FromUID:   authorID,
			IsRead:    false,
		}
		db.Create(&notification)
	}
}

// CreateFeaturedApplicationResultNotification 创建精华申请结果通知
func CreateFeaturedApplicationResultNotification(jpushAppKey, jpushMasterSecret string, db *gorm.DB, toUserID uint, postID, appID uint, status, title, reason string, points int) {
	content := fmt.Sprintf("你的精华申请已通过：《%s》", title)
	if status == "rejected" {
		if points > 0 {
			content = fmt.Sprintf("你的精华申请未通过：%s，因恶意申请扣除 %d 点诚信分", reason, points)
		} else {
			content = fmt.Sprintf("你的精华申请未通过：%s", reason)
		}
	}
	notification := models.Notification{
		UserID:    toUserID,
		Type:      "featured_application",
		Content:   content,
		RelatedID: appID,
		PostID:    postID,
		FromUID:   0, // System
		IsRead:    false,
	}
	db.Create(&notification)

	if jpushAppKey != "" && jpushMasterSecret != "" {
		var user models.User
		if err := db.Where("id = ?", toUserID).Select("device_token").First(&user).Error; err == nil && user.DeviceToken != "" {
			go func() {
				jpush := utils.NewJPushClient(jpushAppKey, jpushMasterSecret)
				extras := map[string]interface{}{
					"type":           "featured_application",
					"post_id":        postID,
					"application_id": appID,
					"status":         status,
				}
				if err := jpush.SendNotification(user.DeviceToken, "系统通知", content, extras); err != nil {
					fmt.Printf("JPush send failed: %v\n", err)
				}
			}()
		}
	}
}

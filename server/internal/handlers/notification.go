package handlers

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"strconv"
	"time"

	"shenliyuan/internal/models"
	textutils "shenliyuan/internal/utils"
	"shenliyuan/utils"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
)

const (
	notificationPageSize       = 30
	notificationMaxPageSize    = 50
	legacyNotificationPageSize = 100

	// NotificationTypeCanteenPending 食堂提交待审核（通知管理员）
	NotificationTypeCanteenPending = "canteen_pending"
	// NotificationTypeCanteenReviewResult 食堂审核结果（通知提交者）
	NotificationTypeCanteenReviewResult = "canteen_review_result"
)

type notificationCursor struct {
	CreatedAt string `json:"created_at"`
	ID        uint   `json:"id"`
}

func encodeNotificationCursor(createdAt time.Time, id uint) string {
	payload, err := json.Marshal(notificationCursor{
		CreatedAt: createdAt.UTC().Format(time.RFC3339Nano),
		ID:        id,
	})
	if err != nil {
		return ""
	}
	return base64.RawURLEncoding.EncodeToString(payload)
}

func decodeNotificationCursor(raw string) (notificationCursor, error) {
	decoded, err := base64.RawURLEncoding.DecodeString(raw)
	if err != nil {
		return notificationCursor{}, err
	}
	var cursor notificationCursor
	if err := json.Unmarshal(decoded, &cursor); err != nil {
		return notificationCursor{}, err
	}
	if cursor.ID == 0 || cursor.CreatedAt == "" {
		return notificationCursor{}, fmt.Errorf("invalid notification cursor")
	}
	if _, err := time.Parse(time.RFC3339Nano, cursor.CreatedAt); err != nil {
		return notificationCursor{}, err
	}
	return cursor, nil
}

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
	if err := h.db.Model(&models.Notification{}).
		Where("user_id = ? AND is_read = ?", uid, false).
		Where("type != ?", models.RetiredNotificationTypeMarketPost).
		Count(&count).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取未读数量失败"})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"count": count,
	})
}

// GetNotifications 获取所有类型的通知列表
func (h *NotificationHandler) GetNotifications(c *gin.Context) {
	userID, _ := c.Get("user_id")
	uid := userID.(uint)
	_, hasLimitParam := c.GetQuery("limit")
	_, hasCursorParam := c.GetQuery("cursor")
	paginationRequested := hasLimitParam || hasCursorParam

	limit := notificationPageSize
	if !paginationRequested {
		// 无 query 的请求仍由旧客户端消费数组格式，保留历史最多 100 条行为。
		limit = legacyNotificationPageSize
	}
	if raw := c.Query("limit"); raw != "" {
		parsed, err := strconv.Atoi(raw)
		if err != nil || parsed <= 0 {
			c.JSON(http.StatusBadRequest, gin.H{
				"code":  "invalid_limit",
				"error": "limit必须是正整数",
			})
			return
		}
		limit = parsed
		if limit > notificationMaxPageSize {
			limit = notificationMaxPageSize
		}
	}

	var cursor notificationCursor
	var cursorTime time.Time
	if raw := c.Query("cursor"); raw != "" {
		var err error
		cursor, err = decodeNotificationCursor(raw)
		if err != nil {
			c.JSON(http.StatusBadRequest, gin.H{
				"code":  "invalid_cursor",
				"error": "通知游标无效",
			})
			return
		}
		cursorTime, _ = time.Parse(time.RFC3339Nano, cursor.CreatedAt)
	}

	var notifications []models.Notification
	query := h.db.Where("user_id = ?", uid).
		Where("type != ?", models.RetiredNotificationTypeMarketPost)
	if c.Query("cursor") != "" {
		query = query.Where(
			"(created_at < ? OR (created_at = ? AND id < ?))",
			cursorTime,
			cursorTime,
			cursor.ID,
		)
	}
	queryLimit := limit
	if paginationRequested {
		queryLimit++
	}
	if err := query.Order("created_at desc, id desc").Limit(queryLimit).Find(&notifications).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取通知失败"})
		return
	}
	hasMore := paginationRequested && len(notifications) > limit
	if hasMore {
		notifications = notifications[:limit]
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

	res := make([]NotificationRes, 0, len(notifications))
	userIDs := make([]uint, 0, len(notifications))
	for _, n := range notifications {
		if n.FromUID > 0 {
			userIDs = append(userIDs, n.FromUID)
		}
	}
	users := make(map[uint]models.User, len(userIDs))
	if len(userIDs) > 0 {
		var records []models.User
		if err := h.db.Where("id IN ?", userIDs).Select("id, nickname, avatar").Find(&records).Error; err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "获取通知发送者失败"})
			return
		}
		for _, user := range records {
			users[user.ID] = user
		}
	}
	for _, n := range notifications {
		item := NotificationRes{Notification: n}
		if u, ok := users[n.FromUID]; ok {
			item.FromUser = &UserInfo{ID: u.ID, Nickname: u.Nickname, Avatar: u.Avatar}
		}
		res = append(res, item)
	}

	nextCursor := ""
	if hasMore && len(notifications) > 0 {
		last := notifications[len(notifications)-1]
		nextCursor = encodeNotificationCursor(last.CreatedAt, last.ID)
	}
	if !paginationRequested {
		// 保留无 query 请求的旧数组响应，避免旧客户端因新增分页 envelope 直接解析失败。
		c.JSON(http.StatusOK, res)
		return
	}
	c.JSON(http.StatusOK, gin.H{
		"items":       res,
		"next_cursor": nextCursor,
		"has_more":    hasMore,
	})
}

// MarkAllRead 将所有通知标记为已读
func (h *NotificationHandler) MarkAllRead(c *gin.Context) {
	userID, _ := c.Get("user_id")
	uid := userID.(uint)

	if err := h.db.Model(&models.Notification{}).Where("user_id = ? AND is_read = ?", uid, false).Update("is_read", true).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "标记已读失败"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "已全部标记为已读"})
}

// MarkSelectedRead 标记指定的通知为已读
func (h *NotificationHandler) MarkSelectedRead(c *gin.Context) {
	userID, _ := c.Get("user_id")
	uid := userID.(uint)

	var req struct {
		IDs []uint `json:"ids"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}

	if len(req.IDs) == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "ids不能为空"})
		return
	}

	if len(req.IDs) > 100 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "单次最多标记100条"})
		return
	}

	res := h.db.Model(&models.Notification{}).
		Where("user_id = ? AND id IN ?", uid, req.IDs).
		Update("is_read", true)

	if res.Error != nil {
		log.Printf("[DB_WARN] Failed to mark selected read: %v", res.Error)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "操作失败"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"updated": res.RowsAffected})
}

// GetPostUnreadReplyNotifications 获取帖子内的未读回复通知
func (h *NotificationHandler) GetPostUnreadReplyNotifications(c *gin.Context) {
	userID, _ := c.Get("user_id")
	uid := userID.(uint)

	postID := c.Param("id")

	var notifications []models.Notification
	if err := h.db.Where("user_id = ? AND post_id = ? AND type = ? AND is_read = ?", uid, postID, "reply", false).
		Order("created_at asc").
		Find(&notifications).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取未读通知失败"})
		return
	}

	type UserInfo struct {
		ID       uint   `json:"id"`
		Nickname string `json:"nickname"`
		Avatar   string `json:"avatar"`
	}

	type UnreadRes struct {
		ID        uint      `json:"id"`
		PostID    uint      `json:"post_id"`
		RelatedID uint      `json:"related_id"`
		Content   string    `json:"content"`
		CreatedAt string    `json:"created_at"`
		FromUser  *UserInfo `json:"from_user"`
	}

	var items []UnreadRes
	for _, n := range notifications {
		item := UnreadRes{
			ID:        n.ID,
			PostID:    n.PostID,
			RelatedID: n.RelatedID,
			Content:   n.Content,
			CreatedAt: n.CreatedAt.Format(time.RFC3339),
		}
		if n.FromUID > 0 {
			var u models.User
			if h.db.Where("id = ?", n.FromUID).Select("id, nickname, avatar").First(&u).Error == nil {
				item.FromUser = &UserInfo{ID: u.ID, Nickname: u.Nickname, Avatar: u.Avatar}
			}
		}
		items = append(items, item)
	}

	c.JSON(http.StatusOK, gin.H{
		"count": len(items),
		"items": items,
	})
}

// GetUnreadReplyNotifications 获取当前用户首页展示的未读回复通知。
// 帖子标题和回复者信息分别批量查询，避免按通知逐条查询产生 N+1。
func (h *NotificationHandler) GetUnreadReplyNotifications(c *gin.Context) {
	userID, _ := c.Get("user_id")
	uid := userID.(uint)

	limit := 20
	if raw := c.Query("limit"); raw != "" {
		parsed, err := strconv.Atoi(raw)
		if err == nil && parsed > 0 {
			if parsed < limit {
				limit = parsed
			}
		}
	}

	query := h.db.Model(&models.Notification{}).
		Where("user_id = ? AND type = ? AND is_read = ?", uid, "reply", false)
	var count int64
	if err := query.Count(&count).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取未读回复失败"})
		return
	}

	var notifications []models.Notification
	if err := query.Order("created_at desc").Limit(limit).Find(&notifications).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取未读回复失败"})
		return
	}

	type userInfo struct {
		ID       uint   `json:"id"`
		Nickname string `json:"nickname"`
		Avatar   string `json:"avatar"`
	}
	type unreadReplyItem struct {
		ID        uint      `json:"id"`
		PostID    uint      `json:"post_id"`
		RelatedID uint      `json:"related_id"`
		Content   string    `json:"content"`
		PostTitle string    `json:"post_title"`
		CreatedAt string    `json:"created_at"`
		FromUser  *userInfo `json:"from_user"`
	}

	postIDs := make([]uint, 0, len(notifications))
	fromUserIDs := make([]uint, 0, len(notifications))
	for _, notification := range notifications {
		if notification.PostID > 0 {
			postIDs = append(postIDs, notification.PostID)
		}
		if notification.FromUID > 0 {
			fromUserIDs = append(fromUserIDs, notification.FromUID)
		}
	}

	type postTitle struct {
		ID    uint
		Title string
	}
	posts := make(map[uint]string, len(postIDs))
	if len(postIDs) > 0 {
		var records []postTitle
		if err := h.db.Model(&models.Post{}).Select("id, title").Where("id IN ?", postIDs).Find(&records).Error; err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "获取帖子信息失败"})
			return
		}
		for _, post := range records {
			posts[post.ID] = post.Title
		}
	}

	users := make(map[uint]userInfo, len(fromUserIDs))
	if len(fromUserIDs) > 0 {
		var records []models.User
		if err := h.db.Select("id, nickname, avatar").Where("id IN ?", fromUserIDs).Find(&records).Error; err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "获取回复者信息失败"})
			return
		}
		for _, user := range records {
			users[user.ID] = userInfo{ID: user.ID, Nickname: user.Nickname, Avatar: user.Avatar}
		}
	}

	items := make([]unreadReplyItem, 0, len(notifications))
	for _, notification := range notifications {
		item := unreadReplyItem{
			ID:        notification.ID,
			PostID:    notification.PostID,
			RelatedID: notification.RelatedID,
			Content:   notification.Content,
			PostTitle: posts[notification.PostID],
			CreatedAt: notification.CreatedAt.Format(time.RFC3339),
		}
		if user, ok := users[notification.FromUID]; ok {
			item.FromUser = &user
		}
		items = append(items, item)
	}

	c.JSON(http.StatusOK, gin.H{"count": count, "items": items})
}

// CreateReplyNotification 创建回复通知（被 reply handler 调用）
func CreateReplyNotification(db *gorm.DB, toUserID, fromUserID, replyID, postID uint, content string) error {
	if toUserID == fromUserID {
		return nil // 不通知自己
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
	return db.Create(&notification).Error
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
	var devices []models.PushDevice
	if err := db.Where("user_id = ? AND enabled = ? AND registration_id <> ''", toUserID, true).
		Find(&devices).Error; err != nil {
		return
	}
	if len(devices) == 0 && user.DeviceToken == "" {
		return
	}

	var fromUser models.User
	if err := db.Where("id = ?", fromUserID).Select("nickname").First(&fromUser).Error; err != nil {
		return
	}

	contentPreview := textutils.TruncateGraphemes(content, 50)

	legacyToken := user.DeviceToken
	go func(devices []models.PushDevice, legacyToken string) {
		jpush := utils.NewJPushClient(jpushAppKey, jpushMasterSecret)
		extras := replyPushExtras(toUserID, replyID, postID)
		title := "您有新的回复"
		alert := fmt.Sprintf("%s: %s", fromUser.Nickname, contentPreview)
		if len(devices) == 0 {
			if err := jpush.SendNotification(legacyToken, title, alert, extras); err != nil {
				fmt.Printf("JPush send failed: %v\n", err)
			}
			return
		}
		for _, device := range devices {
			if err := jpush.SendRegistrationNotification(device.RegistrationID, device.Platform, title, alert, extras); err != nil {
				fmt.Printf("JPush send failed for %s: %v\n", device.Platform, err)
			}
		}
	}(devices, legacyToken)
}

func replyPushExtras(toUserID, replyID, postID uint) map[string]interface{} {
	return map[string]interface{}{
		"post_id":           postID,
		"reply_id":          replyID,
		"type":              "reply",
		"recipient_user_id": toUserID,
	}
}

// CreateReplyNotificationFull 创建回复通知并触发极光推送
func CreateReplyNotificationFull(jpushAppKey, jpushMasterSecret string, db *gorm.DB, toUserID, fromUserID, replyID, postID uint, content string) error {
	if err := CreateReplyNotification(db, toUserID, fromUserID, replyID, postID, content); err != nil {
		return err
	}
	SendJPushNotification(jpushAppKey, jpushMasterSecret, db, toUserID, fromUserID, replyID, postID, content)
	return nil
}

// CreateMarketPostNotification 集市发帖通知（发给所有用户，除了作者自己）
func CreateMarketPostNotification(db *gorm.DB, postID uint, title string, price float64, authorID uint) {
	var users []models.User
	if err := db.Select("id").Where("id != ?", authorID).Find(&users).Error; err != nil {
		log.Printf("[DB_WARN] CreateMarketPostNotification Find users failed: %v", err)
		return
	}

	titlePreview := textutils.TruncateGraphemes(title, 50)
	content := titlePreview
	if price > 0 {
		content = fmt.Sprintf("%s  ¥%.2f", titlePreview, price)
	}

	notifications := make([]models.Notification, 0, len(users))
	for _, user := range users {
		notifications = append(notifications, models.Notification{
			UserID:    user.ID,
			Type:      "market_post",
			Content:   content,
			RelatedID: postID,
			PostID:    postID,
			FromUID:   authorID,
			IsRead:    false,
		})
	}
	if len(notifications) > 0 {
		if err := db.CreateInBatches(&notifications, 200).Error; err != nil {
			log.Printf("[DB_ERROR] CreateMarketPostNotification batch insert failed: %v", err)
		}
	}
}

// CreateCanteenPendingNotification 食堂提交后通知所有管理员审核（仅写库）。
func CreateCanteenPendingNotification(db *gorm.DB, canteenID uint, canteenName string, submitterID uint) {
	var admins []models.User
	if err := db.Select("id").Where("role IN ?", []models.Role{models.RoleAdmin, models.RoleSuperAdmin}).Find(&admins).Error; err != nil {
		log.Printf("[DB_WARN] CreateCanteenPendingNotification Find admins failed: %v", err)
		return
	}
	content := fmt.Sprintf("有新的食堂提交待审核：「%s」", textutils.TruncateGraphemes(canteenName, 50))
	notifications := make([]models.Notification, 0, len(admins))
	for _, admin := range admins {
		notifications = append(notifications, models.Notification{
			UserID:    admin.ID,
			Type:      NotificationTypeCanteenPending,
			Content:   content,
			RelatedID: canteenID,
			FromUID:   submitterID,
			IsRead:    false,
			DedupKey:  fmt.Sprintf("canteen_pending:%d", canteenID),
		})
	}
	if len(notifications) == 0 {
		return
	}
	if err := db.CreateInBatches(&notifications, 200).Error; err != nil {
		log.Printf("[DB_ERROR] CreateCanteenPendingNotification batch insert failed: %v", err)
		return
	}
	// 管理端待办与角标依赖未读通知，推送仅在站内，避免重复打扰。
}

// CreateCanteenReviewResultNotification 审核通过/驳回后通知提交者（仅写库）。
// expReward>0 时在通过通知中告知提交者获得的奖励经验。
func CreateCanteenReviewResultNotification(db *gorm.DB, canteenID, submitterID uint, canteenName string, approved bool, reason string, expReward int) {
	if submitterID == 0 {
		return
	}
	content := fmt.Sprintf("你提交的食堂「%s」审核已通过，现已显示在商家列表", textutils.TruncateGraphemes(canteenName, 50))
	if approved && expReward > 0 {
		content += fmt.Sprintf("，获得 %d 经验奖励", expReward)
	}
	if !approved {
		content = fmt.Sprintf("你提交的食堂「%s」未能通过审核", textutils.TruncateGraphemes(canteenName, 50))
		if reason != "" {
			content = fmt.Sprintf("你提交的食堂「%s」未能通过审核：%s", textutils.TruncateGraphemes(canteenName, 50), textutils.TruncateGraphemes(reason, 80))
		}
	}
	notification := models.Notification{
		UserID:    submitterID,
		Type:      NotificationTypeCanteenReviewResult,
		Content:   content,
		RelatedID: canteenID,
		FromUID:   0, // System
		IsRead:    false,
		DedupKey:  fmt.Sprintf("canteen_review_result:%d:%t", canteenID, approved),
	}
	if err := db.Create(&notification).Error; err != nil {
		log.Printf("[DB_ERROR] CreateCanteenReviewResultNotification failed: %v", err)
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
	if err := db.Create(&notification).Error; err != nil {
		log.Printf("[DB_ERROR] CreateFeaturedApplicationResultNotification failed: %v", err)
		return
	}

	if jpushAppKey != "" && jpushMasterSecret != "" {
		var user models.User
		if err := db.Where("id = ?", toUserID).Select("device_token").First(&user).Error; err == nil {
			var devices []models.PushDevice
			if err := db.Where("user_id = ? AND enabled = ? AND registration_id <> ''", toUserID, true).Find(&devices).Error; err != nil {
				return
			}
			if len(devices) == 0 && user.DeviceToken == "" {
				return
			}
			legacyToken := user.DeviceToken
			go func(devices []models.PushDevice, legacyToken string) {
				jpush := utils.NewJPushClient(jpushAppKey, jpushMasterSecret)
				extras := map[string]interface{}{
					"type":           "featured_application",
					"post_id":        postID,
					"application_id": appID,
					"status":         status,
				}
				if len(devices) == 0 {
					if err := jpush.SendNotification(legacyToken, "系统通知", content, extras); err != nil {
						fmt.Printf("JPush send failed: %v\n", err)
					}
					return
				}
				for _, device := range devices {
					if err := jpush.SendRegistrationNotification(device.RegistrationID, device.Platform, "系统通知", content, extras); err != nil {
						fmt.Printf("JPush send failed for %s: %v\n", device.Platform, err)
					}
				}
			}(devices, legacyToken)
		}
	}
}

package handlers

import (
	"net/http"
	"strconv"

	"shenliyuan/internal/models"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

// LikeHandler 点赞处理器
type LikeHandler struct {
	db *gorm.DB
}

// NewLikeHandler 创建点赞处理器
func NewLikeHandler(db *gorm.DB) *LikeHandler {
	return &LikeHandler{db: db}
}

// LikeInput 点赞输入
type LikeInput struct {
	Type string `json:"type" binding:"required"` // post/reply
}

// LikePost 点赞帖子
func (h *LikeHandler) LikePost(c *gin.Context) {
	userID, _ := c.Get("user_id")
	postIDStr := c.Param("id")
	postID, err := strconv.ParseUint(postIDStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的帖子ID"})
		return
	}

	var post models.Post
	if err := h.db.Select("id", "author_id").First(&post, postID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "帖子不存在"})
		return
	}

	like := models.Like{
		UserID:     userID.(uint),
		TargetType: "post",
		TargetID:   uint(postID),
	}

	isDuplicate := false
	err = h.db.Transaction(func(tx *gorm.DB) error {
		result := tx.Clauses(clause.OnConflict{DoNothing: true}).Create(&like)
		if result.Error != nil {
			return result.Error
		}
		if result.RowsAffected == 0 {
			isDuplicate = true
			return nil
		}
		if err := tx.Model(&models.Post{}).Where("id = ?", postID).Update("like_count", gorm.Expr("like_count + 1")).Error; err != nil {
			return err
		}
		if err := tx.Model(&models.User{}).Where("id = ?", post.AuthorID).Update("total_likes_received", gorm.Expr("total_likes_received + 1")).Error; err != nil {
			return err
		}
		return nil
	})

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "数据库操作失败"})
		return
	}

	if isDuplicate {
		c.JSON(http.StatusOK, gin.H{"message": "已点赞"})
		return
	}

	c.JSON(http.StatusCreated, like)
}

// UnlikePost 取消点赞帖子
func (h *LikeHandler) UnlikePost(c *gin.Context) {
	userID, _ := c.Get("user_id")
	postIDStr := c.Param("id")
	postID, err := strconv.ParseUint(postIDStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的帖子ID"})
		return
	}

	var post models.Post
	if err := h.db.Select("id", "author_id").First(&post, postID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "帖子不存在"})
		return
	}

	err = h.db.Transaction(func(tx *gorm.DB) error {
		result := tx.Where("user_id = ? AND target_type = ? AND target_id = ?", userID, "post", postID).Delete(&models.Like{})
		if result.Error != nil {
			return result.Error
		}
		if result.RowsAffected > 0 {
			if err := tx.Model(&models.Post{}).Where("id = ?", postID).Update("like_count", gorm.Expr("GREATEST(like_count - 1, 0)")).Error; err != nil {
				return err
			}
			if err := tx.Model(&models.User{}).Where("id = ?", post.AuthorID).Update("total_likes_received", gorm.Expr("GREATEST(total_likes_received - 1, 0)")).Error; err != nil {
				return err
			}
		}
		return nil
	})

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "数据库操作失败"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "已取消点赞"})
}

// LikeReply 点赞回复
func (h *LikeHandler) LikeReply(c *gin.Context) {
	userID, _ := c.Get("user_id")
	replyIDStr := c.Param("id")
	replyID, err := strconv.ParseUint(replyIDStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的回复ID"})
		return
	}

	var reply models.Reply
	if err := h.db.Select("id", "author_id").First(&reply, replyID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "回复不存在"})
		return
	}

	like := models.Like{
		UserID:     userID.(uint),
		TargetType: "reply",
		TargetID:   uint(replyID),
	}

	isDuplicate := false
	err = h.db.Transaction(func(tx *gorm.DB) error {
		result := tx.Clauses(clause.OnConflict{DoNothing: true}).Create(&like)
		if result.Error != nil {
			return result.Error
		}
		if result.RowsAffected == 0 {
			isDuplicate = true
			return nil
		}
		if err := tx.Model(&models.Reply{}).Where("id = ?", replyID).Update("like_count", gorm.Expr("like_count + 1")).Error; err != nil {
			return err
		}
		return nil
	})

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "数据库操作失败"})
		return
	}

	if isDuplicate {
		c.JSON(http.StatusOK, gin.H{"message": "已点赞"})
		return
	}

	c.JSON(http.StatusCreated, like)
}

// UnlikeReply 取消点赞回复
func (h *LikeHandler) UnlikeReply(c *gin.Context) {
	userID, _ := c.Get("user_id")
	replyIDStr := c.Param("id")
	replyID, err := strconv.ParseUint(replyIDStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的回复ID"})
		return
	}

	var reply models.Reply
	if err := h.db.Select("id", "author_id").First(&reply, replyID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "回复不存在"})
		return
	}

	err = h.db.Transaction(func(tx *gorm.DB) error {
		result := tx.Where("user_id = ? AND target_type = ? AND target_id = ?", userID, "reply", replyID).Delete(&models.Like{})
		if result.Error != nil {
			return result.Error
		}
		if result.RowsAffected > 0 {
			if err := tx.Model(&models.Reply{}).Where("id = ?", replyID).Update("like_count", gorm.Expr("GREATEST(like_count - 1, 0)")).Error; err != nil {
				return err
			}
		}
		return nil
	})

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "数据库操作失败"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "已取消点赞"})
}

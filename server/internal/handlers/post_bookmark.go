package handlers

import (
	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
	"net/http"
	"shenliyuan/internal/models"
	"strconv"
	"time"
)

func (h *PostHandler) PutBookmark(c *gin.Context) {
	id, err := strconv.ParseUint(c.Param("id"), 10, 32)
	if err != nil || id == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "帖子编号无效"})
		return
	}
	var post models.Post
	if err = h.db.Where("status IN ?", []models.PostStatus{models.PostStatusNormal, models.PostStatusSold, models.PostStatusClosed}).First(&post, uint(id)).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "帖子不可访问"})
		return
	}
	bookmark := models.PostBookmark{UserID: c.GetUint("user_id"), PostID: post.ID, CreatedAt: time.Now()}
	if err = h.db.Clauses(clause.OnConflict{DoNothing: true}).Create(&bookmark).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "收藏失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"bookmarked": true})
}

func (h *PostHandler) DeleteBookmark(c *gin.Context) {
	id, err := strconv.ParseUint(c.Param("id"), 10, 32)
	if err != nil || id == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "帖子编号无效"})
		return
	}
	if err = h.db.Where("user_id = ? AND post_id = ?", c.GetUint("user_id"), uint(id)).Delete(&models.PostBookmark{}).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "取消收藏失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"bookmarked": false})
}

func (h *PostHandler) ListBookmarks(c *gin.Context) {
	page, limit, offset, err := ParsePaginationStrict(c, 20, 50)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "分页参数无效"})
		return
	}
	q := h.db.Model(&models.Post{}).Joins("JOIN post_bookmarks ON post_bookmarks.post_id = posts.id").Where("post_bookmarks.user_id = ? AND posts.status IN ?", c.GetUint("user_id"), []models.PostStatus{models.PostStatusNormal, models.PostStatusSold, models.PostStatusClosed})
	var posts []models.Post
	if err := q.Session(&gorm.Session{}).Preload("Author").Preload("Images").Preload("Images.File").Scopes(withPostImageVariants).Order("post_bookmarks.created_at DESC, posts.id DESC").Offset(offset).Limit(limit+1).Find(&posts).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "读取收藏失败"})
		return
	}
	hasMore := len(posts) > limit
	if hasMore {
		posts = posts[:limit]
	}
	if len(posts) > 0 {
		h.hydratePosts(c, posts, time.Now())
	}
	c.JSON(http.StatusOK, gin.H{"posts": posts, "page": page, "has_more": hasMore})
}

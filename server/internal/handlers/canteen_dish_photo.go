package handlers

import (
	"errors"
	"net/http"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
)

// errDishGalleryFull 该菜品已有 3 张实拍。
var errDishGalleryFull = errors.New("dish_gallery_full")

// MaxDishNameLength 菜名最大可见字符数（与客户端 maxLength: 40 对齐）。
const MaxDishNameLength = 40

// errDishPhotoAlreadyReviewed 该实拍已被审核处理。
var errDishPhotoAlreadyReviewed = errors.New("dish_photo_already_reviewed")

// CanteenDishPhotoHandler 菜品实拍投稿接口。
type CanteenDishPhotoHandler struct {
	db *gorm.DB
}

func NewCanteenDishPhotoHandler(db *gorm.DB) *CanteenDishPhotoHandler {
	return &CanteenDishPhotoHandler{db: db}
}

// SubmitDishPhoto 是旧客户端路径的兼容别名。
//
// 独立菜品投稿流程已退休，现在通过食堂评价直接创建 active 菜品。
// POST /api/canteens/:canteenId/dish-photos
func (h *CanteenDishPhotoHandler) SubmitDishPhoto(c *gin.Context) {
	c.JSON(http.StatusGone, gin.H{
		"code":  "dish_submission_retired",
		"error": "菜品与实拍现已通过食堂评价提交，请更新客户端",
	})
}

// errDishNotFound 菜品不存在或不属于该食堂。
var errDishNotFound = errors.New("dish not found")

// errInvalidDishName 菜名为空。
var errInvalidDishName = errors.New("invalid dish name")
